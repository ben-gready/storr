## ---
## title: "storr"
## author: "Rich FitzJohn"
## date: "`r Sys.Date()`"
## output: rmarkdown::html_vignette
## vignette: >
##   %\VignetteIndexEntry{storr}
##   %\VignetteEngine{knitr::rmarkdown}
##   \usepackage[utf8]{inputenc}
## ---

library(storr)

## At the moment, `storr` requires a driver to be explicitly given;
## that will change to be a bit more user-friendly shortly.

## The idea with different drivers is that different ways of storing
## data have different trade-offs in terms of speed, size,
## concurrency, etc; the approach here should allow different
## backends to be switched in and out while keeping the same
## user-facing interface.

## `driver_rds` stores contents at some path by saving out to rds
## files.  Here I'm using a temporary directory for the path; the
## driver will create a number of subdirectories here.
path <- tempfile("storr_")
dr <- storr::driver_rds(path)

## With this driver object we can create the `storr` object which is
## what we actually interact with:
st <- storr::storr(driver=dr)

## # Key-value store:

## The most simple way of interacting with a `storr` object is
## `get`/`set`/`del` for getting, setting and deleting data stored at
## some key.  To store data:
st$set("mykey", mtcars)

## To get the data back
head(st$get("mykey"))

## What is in the `storr`?
st$list()

## Or, much faster, test for existance of a particular key:
st$exists("mykey")

st$exists("another_key")

## To delete it:
st$del("mykey")

## It's gone!
st$list()

## # Lists and indexable serialisation

## A disadvantage of saving R objects to disk is you have to read the
## entire thing in at once.  `storr` addresses one specific solution
## to this problem; allowing simple indexing of objects that are
## list-like (i.e., things you could throw at `lapply` productively).

## Here's a daft object that we want to serialise but address by index
## later.
set.seed(1)
obj <- setNames(lapply(1:5, runif), letters[1:5])
obj

## Rather than use `set`, use `set_list` to assign the object against
## a key.
st$set_list("mylist", obj)

## The object appears in the `storr` as before
st$list()

## and can be accessed in its entirety:
st$get("mylist")

## but it has a different type:
st$type("mylist")

## Can be queried on length:
st$length_list("mylist")

## To access an individual element:
st$get_list_element("mylist", 2)

## To access multiple elements (names are dropped at present, but
## might be retrieveable as an option in future)
st$get_list_elements("mylist", c(1, 3, 5))

## To assign to individual elements:
st$set_list_element("mylist", 3, "a different value")
st$get_list_element("mylist", 3)

## Retrieve the whole list again; names are still there but the value
## of the 3rd element has changed.
st$get("mylist")

## Lists can be deleted as before
st$del("mylist")

## # Import / export

## Objects can be imported in and exported out of a `storr`;

## Import from a list, environment or another `storr`
st$import(list(a=1, b=2))
st$list()
st$get("a")

## Export to an environment or another `storr`
e <- new.env(parent=emptyenv())
st$export(e)
ls(e)
e$a

## Convenience function that does the same as the above (exports to a
## new environment that has `.GlobalEnv` as its parent)
e2 <- st$to_environment()
ls(e2)
parent.env(e2)

st2 <- storr::storr(driver=storr::driver_rds(tempfile("storr_")))
st2$list()
st2$import(st)
st2$list()

## # Supported backends

## * environments (`driver_environment`) - mostly for debugging and
## transient storage, but by far the fastest.
## * on disk with rds (`driver_rds`) - zero dependencies, quite fast,
## will suffer under high concurrency because there is no file
## locking.
## * Redis (`driver_redis`) - uses
## [`RcppRedis`](https://github.com/eddelbuettel/rcppredis) to store
## the data in a [Redis](http://redis.io) database.  Slower than rds,
## but can allow multiple R processes to share the same set of objects.
## * rlite (`driver_rlite`) - stores data in an
## [rlite](https://github.com/seppo0010/rlite) using
## [`rrlite`](https://github.com/ropensci/rrlite).  This is the
## slowest at present and does not support concurrency at all.  But
## rlite has the potential to be as useful as SQLite is so this will
## improve.

## # Implementation details

## `storr` includes a few useful features that are common to all
## drivers.

## ## Content addressable lookup

## The only thing that is stored against a key is the hash of some
## object.  Each driver does this a different way, but for the rds
## driver it stores small text files that list the hash in them.  So:
dir(file.path(st$driver$path_keys, "objects"))
readLines(file.path(st$driver$path_keys, "objects", "a"))
st$get_hash("a")

## Then there is one big pool of hash / value pairs:
st$list_hashes()

## in the rds driver these are stored like so:
dir(file.path(st$driver$path_data))

## This is going to need garbage collecting every so often - no
## reference counting is done so stale objects can build up.
st$gc()
st$list_hashes()
dir(file.path(st$driver$path_data))

## Eventually this might be automated but for now it's not.

## ## Environment-based caching

## Every time data passes across a `get` or `set` method, `storr`
## stores the data in an environment within the `storr` object.
## Because we store the content against its hash, it's always in sync
## with what is saved to disk.  That means that the look up process
## goes like this:
##
## 1. Ask for a key, get returned the hash of the content
## 2. Check in the caching environment for that hash and return that
## if present
## 3. If not present, read content from disk/db/wherever the driver
## stores it and save it into the caching environment
##
## Because looking up data in the environment is likely to be orders
## of magnitide faster than reading from disks or databases, this
## means that commonly accessed data will be accessed at a similar
## speed to native R objects, while still immediately reflecting
## changes to the content (because that would mean the hash changes)

## To demonstrate:
st <- storr::storr(driver=storr::driver_rds(tempfile("storr_")))

## This is the caching environent; currently empty
ls(st$envir)

## Set some key to some data:
set.seed(2)
st$set("mykey", runif(100))

## The environment now includes an object with a *name* that is the
## same as the *hash* of its contents:
ls(st$envir)

## Extract the object from the environment and hash it
storr:::hash_object(st$envir[[ls(st$envir)]])

## When we look up the value stored against key `mykey`, the first
## step is to check the key/hash map; this returns the key above (this
## step *does* involve reading from disk)
st$get_hash("mykey")

## It then calls `$get_value` to extract the value associated with
## that hash - the first thing that function does is try to locate the
## hash in the environment, otherwise it reads the data from wherever
## the driver stores it.
st$get_value

## The speed up is going to be fairly context dependent, but 10x seems
## pretty good in this case (some of the overhead is simply a longer
## code path as we call out to the driver).
hash <- st$get_hash("mykey")
microbenchmark::microbenchmark(st$get_value(hash, use_cache=TRUE),
                               st$get_value(hash, use_cache=FALSE))