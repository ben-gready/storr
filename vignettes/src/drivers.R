## ---
## title: "storr drivers"
## author: "Rich FitzJohn"
## date: "`r Sys.Date()`"
## output: rmarkdown::html_vignette
## vignette: >
##   %\VignetteIndexEntry{storr drivers}
##   %\VignetteEngine{knitr::rmarkdown}
##   \usepackage[utf8]{inputenc}
## ---

## Requirements for storr drivers.

## The idea here is that you implement a handful of methods and the
## package will construct a common interface around them.  There are
## built-in tests in the package to ensure that the driver behaves
## correctly, and infrastructure to help with running those tests.

## To demonstrate we'll write a wrapper around RSQLite to store data.

## # How it works and what we need

## The required methods are:

## Given a driver `dr`, storr retrieves values (`get`) by running:

## ```r
## dr$exists_key(key, namespace)
## hash <- dr$get_hash(key, namespace)
## dr$exists_hash(hash)
## dr$get_object(hash)
## ```

## which:
##
## 1. checks that a key exists (keys being defined by a combination of
## key and namespace)
## 2. retrieves the object hash stored against that key
## 3. checks that the hash is actually present in the database
## 4. retrieves the object stored against the hash
##
## hashes are stored as strings, while objects are *serialised R
## objects*, usually stored in binary.  The driver is responsible for
## serialisation/deserialisation as that will depend on the properties
## of the driver.
##
## storr will take care of throwing appropriate errors if the object
## is not found (which requires the calls to `exists_key` and
## `exists_hash`).

## `set` works in a similar way:
##
## ```r
## hash <- storr:::hash_object(hash)
## if (!dr$exists_hash(hash)) {
##   dr$set_object(hash, value)
## }
## dr$set_hash(key, namespace, hash)
## ```
##
## The important part here is that storr will avoid setting the object
## if it can be avoided (i.e., if the hash is present in the database
## then the object has already been stored -- because saving the
## actual data is likely to be the slowest part it's worth avoiding).
##
## 1. if the hash is not present, save the (serialised) object against
## the hash.
## 2. store the hash against the key and namespace.

## The total list of required functions is:

## (see TODO.md)

## ## A digression: key/value stores and SQL

## SQL data bases are probably not going to be a great place to store
## key/value data (especially very large objects) and this section is
## not meant to be normative.  Instead, this is one possible route
## that could be taken.  Recent version of postgresql include
## interfaces that support first class key/value (`hstore`) which
## would be prefereable to this.

## Details from
## [here](http://jfaganuk.github.io/2015/01/12/storing-r-objects-in-sqlite-tables/)

## Start with a SQLite connection (similar things can be done with
## other DBI drivers but at present this uses one SQLite-only function
## below):
con <- DBI::dbConnect(RSQLite::SQLite(), ":memory:")

## This will create a table into which we can put key/value pairs.
table <- "mydata"
sql <- c(sprintf("CREATE TABLE IF NOT EXISTS %s", table),
         "(name string PRIMARY KEY,",
         "value blob)")
DBI::dbGetQuery(con, paste(sql, collapse=" "))

## Then take an object, serialise it, and stuff it into the blob:
value <- mtcars
name <- "mtcars"

dat <- data.frame(name=name,
                  value=I(list(serialize(value, NULL))),
                  stringsAsFactors=FALSE)
sql <- sprintf("INSERT into %s (name, value) values (:name, :value)", table)
RSQLite::dbGetPreparedQuery(con, sql, bind.data=dat)

## The complicated bit here is using the `RSQLite::dbGetPreparedQuery`
## to inject the raw byte sequence of the serialised object into the
## `value` column (note that this is not a `DBI` function, otherwise .
## I believe that similar approaches are possible in other DBI
## drivers.  With the new development version of DBI/RSQLite this will
## change to using `DBI::dbBind`:

###+ eval=FALSE
## DBI::dbGetQuery(con, sql, bind.data=dat)

## which is great because it means that the driver below would work
## for other DBI-compliant backends (development versions of RPostgres
## and RMySQL at least).

## We can retrieve the data by name:
sql <- sprintf('SELECT value FROM %s WHERE name == "%s"', table, name)
x <- unserialize(DBI::dbGetQuery(con, sql)[[1]][[1]])
identical(x, value)

## ## Implementing the storr driver

## For consistency with other `storr` functions, even though the
## driver is an R6 object, we construct it using a plain R function
## (not the `$new()` method of an R6 generator.  This is because the
## driver *could* be implemented as a function that generates a list
## of closures or a reference class.

## There are quite a few required functions to implement.  Below, the
## value in parentheses after the function signature is the expected
## return type.

## * `type()` (character): Takes no argument and returns a string with
##   the "type" of the driver.  This can be any identifier.
## * `destroy()` (NULL): Takes no argument and destroys all data
##   associated with the driver.  Best to also leave the driver in a
##   state where it can't be used, though this is not enforced.

## * `set_hash(key, namespace, hash)` (NULL): Given strings for `key`,
##   `namespace` and `hash` against the key/namespace pair.
## * `get_hash(key, namespace)` (character): Given strings for `key`, and
##   `namespace`, return the hash of the object.

## * `set_object(hash, value)` (NULL): Given a string `hash` and an
##   arbitrary object `value`, store the object against the hash.
##   Serialisation will likely be needed here (e.g., `serialize(value,
##   NULL)`).
## * `get_object(hash)` (object): Given a string `hash` return the R
##   object stored against it.  Deserialisation will likely be needed
##   here (e.g., `unserialize(dat)`)

## * `exists_key(key, namespace)` (logical): Given strings for `key` and
##   `namespace` return `TRUE` if there is a hash stored against the
##   key/namespace pair, `FALSE` otherwise.
## * `exists_hash(hash)` (logical): Given a string for `hash`, return
##   `TRUE` if there is an object stored against the hash.

## * `del_key(key, namespace)` (logical): Given strings for `key` and
##   `namespace`, delete this key if it exists.  Return `TRUE` if the key
##   existed, `FALSE` otherwise.
## * `del_hash(hash)` (logical): Given a string for `hash` the object if
##   it exists.  Return `TRUE` if the hash existed, `FALSE` otherwise.

## * `list_hashes()` (character vector): Return a character vector of all
##   known hashes.
## * `list_namespaces()` (character vector): Return a character vector of
##   all known namespaces.
## * `list_keys(namespace)` (character vector): Given a string
##   `namespace`, return a character vector of all known keys within the
##   namespace.

## The arguments to the constructor will be
##
## * `path`: Path to the SQLite database
## * `tbl_data`: Name of the table to store the data (hash/object pairs) in.
## * `tbl_keys`: Name of the table to store the keys
##   (key/namespace/hash triplets) in.

## The SQL queries are a bit ugly but hopefully straightforward enough
## to follow.

driver_sqlite <- function(path, tbl_data="storr_data", tbl_keys="storr_keys") {
  .R6_driver_sqlite$new(path, tbl_data, tbl_keys)
}

## The R6 class definition that implements the functions above, with a
## little commentry throughout.
.R6_driver_sqlite <- R6::R6Class(
  "driver_sqlite",
  public=list(
    ## Public data members
    con=NULL,
    tbl_data=NULL,
    tbl_keys=NULL,

    ## On initialisation we'll create the two tables but only if they
    ## do not exist.  We can enforce the constraint that hash must be
    ## unique within tbl_data and key/`namespace pairs must be unique
    ## within tbl_keys.
    initialize=function(path, tbl_data, tbl_keys) {
      self$con <- DBI::dbConnect(RSQLite::SQLite(), path)
      self$tbl_data <- tbl_data
      self$tbl_keys <- tbl_keys

      sql <- c(sprintf("CREATE TABLE if NOT EXISTS %s", tbl_data),
               "(hash string PRIMARY KEY NOT NULL,",
               "value blob NOT NULL)")
      DBI::dbGetQuery(self$con, paste(sql, collapse=" "))

      sql <- c(sprintf("CREATE TABLE IF NOT EXISTS %s", tbl_keys),
               "(namespace string NOT NULL,",
               "key string NOT NULL,",
               "hash string NOT NULL,",
               "PRIMARY KEY (namespace, key))")
      DBI::dbGetQuery(self$con, paste(sql, collapse=" "))
    },

    ## This is purely for identification later.
    type=function() {
      "DBI/sqlite"
    },

    ## Total destruction of the driver; delete all data stored in both
    ## tables, then delete our database connection to render the
    ## driver useless.
    destroy=function() {
      DBI::dbRemoveTable(self$con, self$tbl_data)
      DBI::dbRemoveTable(self$con, self$tbl_keys)
      self$con <- NULL
    },

    ## Return the hash value given a key/namespace pair
    get_hash=function(key, namespace) {
      sql <- sprintf('SELECT hash FROM "%s" WHERE namespace="%s" AND key="%s"',
                     self$tbl_keys, namespace, key)
      DBI::dbGetQuery(self$con, sql)[[1]]
    },
    ## Set the key/namespace pair to a hash
    set_hash=function(key, namespace, hash) {
      sql <- c(sprintf("INSERT OR REPLACE INTO %s", self$tbl_keys),
               sprintf('(namespace, key, hash) VALUES ("%s", "%s", "%s")',
                       namespace, key, hash))
      DBI::dbGetQuery(self$con, paste(sql, collapse=" "))
    },

    ## Return a (deserialised) R object, given a hash
    get_object=function(hash) {
      sql <- c(sprintf("SELECT value FROM %s", self$tbl_data),
               sprintf('WHERE hash = "%s"', hash))
      value <- DBI::dbGetQuery(self$con, paste(sql, collapse=" "))[[1]]
      unserialize(value[[1]])
    },

    ## Set a (serialised) R object against a hash.  This would be
    ## considerably simpler (but probably slower and less accurate) if we
    ## serialised to string with:
    ##   rawToChar(serialize(value, NULL, TRUE))
    set_object=function(hash, value) {
      dat <- data.frame(hash=hash,
                        value=I(list(serialize(value, NULL))),
                        stringsAsFactors=FALSE)
      sql <- c(sprintf("INSERT OR REPLACE INTO %s", self$tbl_data),
               "(hash, value) VALUES (:hash, :value)")
      RSQLite::dbGetPreparedQuery(self$con, paste(sql, collapse=" "),
                                  bind.data=dat)
    },

    ## Check if a key/namespace pair exists.
    exists_key=function(key, namespace) {
      sql <- sprintf('SELECT 1 FROM %s WHERE namespace = "%s" AND key = "%s"',
                     self$tbl_keys, namespace, key)
      nrow(DBI::dbGetQuery(self$con, sql)) > 0L
    },
    ## Check if a hash exists
    exists_hash=function(hash) {
      sql <- sprintf('SELECT 1 FROM %s WHERE hash = "%s"',
                     self$tbl_data, hash)
      nrow(DBI::dbGetQuery(self$con, sql)) > 0L
    },

    ## Delete a key.  Because of the requirement to return TRUE/FALSE on
    ## successful/unsuccessful key deletion this includes an exists_key()
    ## step first.
    del_key=function(key, namespace) {
      if (self$exists_key(key, namespace)) {
        sql <- sprintf('DELETE FROM %s WHERE namespace = "%s" AND key = "%s"',
                       self$tbl_keys, namespace, key)
        DBI::dbGetQuery(self$con, sql)
        TRUE
      } else {
        FALSE
      }
    },
    ## Delete a hash
    del_hash=function(hash) {
      if (self$exists_hash(hash)) {
        sql <- sprintf('DELETE FROM %s WHERE hash = "%s"', self$tbl_data, hash)
        DBI::dbGetQuery(self$con, sql)
        TRUE
      } else {
        FALSE
      }
    },

    ## List hashes, namespaces and keys.  Because the SQLite driver seems to
    ## return numeric(0) if the result set is empty, we need as.character here.
    list_hashes=function() {
      sql <- sprintf("SELECT hash FROM %s", self$tbl_data)
      as.character(DBI::dbGetQuery(self$con, sql)[[1]])
    },
    list_namespaces=function() {
      sql <- sprintf("SELECT DISTINCT namespace FROM %s", self$tbl_keys)
      as.character(DBI::dbGetQuery(self$con, sql)[[1]])
    },
    list_keys=function(namespace) {
      sql <- sprintf('SELECT key FROM %s WHERE namespace="%s"',
                     self$tbl_keys, namespace)
      as.character(DBI::dbGetQuery(self$con, sql)[[1]])
    }
  ))

## Next, let's give the driver a little workout.
dr <- driver_sqlite(":memory:")

## Start with the hash part of the database.  At first we have no
## hashes in the database:
dr$list_hashes()

## so `exists_hash` returns `FALSE`:
hash <- digest::digest(mtcars)
dr$exists_hash(hash)

## We can set an object against a hash:
dr$set_object(hash, mtcars)

## and then `exists_hash` will return `TRUE`
dr$exists_hash(hash)

## and we can retrieve the object:
head(dr$get_object(hash))

## Our set of hashes:
dr$list_hashes()

## Delete the hash:
dr$del_hash(hash)

## And it's gone:
dr$list_hashes()
dr$exists_hash(hash)

## Set up a key
key <- "aaa"
namespace <- "ns"
dr$set_hash(key, namespace, hash)

## Which now exists:
dr$exists_key(key, namespace)

## And can be listed:
dr$list_keys(namespace)

## and the hash against the key returned:
dr$get_hash(key, namespace)

dr$del_key(key, namespace)
dr$exists_key(key, namespace)
dr$list_keys(namespace)

## OK, so this *seems* to be working.  But how do we test if it is
## actually working?  `storr` provides an automatic testing facility
## based on `testthat`.
storr:::test_driver("DBI/sqlite", function() driver_sqlite(":memory:"))

## The first argument is the name of the driver (needs to be what is
## returned by `type()` above) and the second is a function that
## generates a database that we are allowed to write anything to and
## then destroy when complete.  So `:memory:` is a good path here!

## Now that the driver works, we can write the wrapper function:
storr_sqlite <- function(path,
                         tbl_data="storr_data", tbl_keys="storr_keys",
                         default_namespace="objects") {
  storr::storr(driver_sqlite(path, tbl_data, tbl_keys),
               default_namespace)
}

## and construct a `storr` with it:
st_sql <- storr_sqlite(":memory:")

## Nothing in the storr:
st_sql$list()

## Set some data:
st_sql$set("foo", runif(10))

## Retrieve it:
st_sql$get("foo")

## Delete it:
st_sql$del("foo")
st_sql$list()

## Underlying data is still kicking around:
st_sql$list_hashes()
st_sql$get_value(st_sql$list_hashes())

## But we can garbage collect:
st_sql$gc()
st_sql$list_hashes()

## As implemented (totally naively) above, this driver is quite a bit
## slower than the rds driver (which is ~= the same speed as the redis
## driver)
st_rds <- storr::storr_rds(tempfile())
microbenchmark::microbenchmark(
  st_sql$set(key, runif(10), use_cache=FALSE),
  st_rds$set(key, runif(10), use_cache=FALSE))

microbenchmark::microbenchmark(
  st_sql$get(key, use_cache=FALSE),
  st_rds$get(key, use_cache=FALSE))

st_sql$destroy()
st_rds$destroy()

## This is not really SQL's strong suit.  But if key/value storage is
## a small part of an application that already uses SQLite for storage
## then this approach could be a sensible move.