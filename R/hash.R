## All the bits related to object hashing and serialisation
make_hash_serialized_object <- function(hash_algorithm, skip_version) {
  hash <- digest::digest
  hash_algorithm <- hash_algorithm %||% "md5"
  skip <- if (skip_version) 14L else 0L
  function(x) {
    hash(x, hash_algorithm, skip = skip, serialize = FALSE)
  }
}

make_serialize_object <- function(drop_r_version, string, xdr = TRUE) {
  if (string) {
    ## TODO: check R version is at least 3.2.0 here
    function(object) rawToChar(serialize(object, NULL, NA, xdr))
  } else if (drop_r_version) {
    function(object) serialize_object_drop_r_version(object, xdr)
  } else {
    function(object) serialize(object, NULL, FALSE, xdr)
  }
}

## serialize_object <- function(object, xdr = TRUE, drop_r_version = FALSE) {
##   if (drop_r_version) {
##     serialize_object_drop_r_version(object, xdr)
##   } else {
##     serialize(object, NULL, xdr = xdr)
##   }
## }

## serialize_str <- function(x) {
##   rawToChar(serialize(x, NULL, TRUE))
## }
## unserialize_str <- function(x) {
##   unserialize(charToRaw(x))
## }

unserialize_safe <- function(x) {
  if (is.character(x)) {
    unserialize(charToRaw(x))
  } else if (is.raw(x)) {
    unserialize(x)
  } else {
    stop("Invalid input")
  }
}

## This is needed to support the case where the hash must apply to the
## *entire* structure, just just the relevant bytes.
STORR_R_VERSION_BE <- as.raw(c(0L, 3L, 2L, 0L))
STORR_R_VERSION_LE <- as.raw(c(0L, 2L, 3L, 0L))
serialize_object_drop_r_version <- function(object, xdr = TRUE) {
  dat <- serialize(object, NULL, xdr = xdr, version = 2L)
  dat[7:10] <- if (xdr) STORR_R_VERSION_BE else STORR_R_VERSION_LE
  dat
}

## For current R (3.3.2 or thereabouts) writeBin does not work with
## long vectors.  We can work around this for now, but in future
## versions this will just use native R support.
##
## The workaround is to *unserialize* and then use saveRDS to
## serialize directly to a connection.  This is far from ideal, but is
## faster than the previous approach of iterating through the raw
## vector and writing it bit-by-bit to a file (~30s for that approach,
## vs ~10s for this one).
write_serialized_rds <- function(value, filename, compress, long = 2^31 - 2) {
  con <- (if (compress) gzfile else file)(filename, "wb")
  on.exit(close(con))
  len <- length(value)
  if (len < long) {
    writeBin(value, con)
  } else {
    message("Repacking large object")
    saveRDS(unserialize(value), con)
  }
}