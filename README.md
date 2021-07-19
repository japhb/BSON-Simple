[![Actions Status](https://github.com/japhb/BSON-Simple/workflows/test/badge.svg)](https://github.com/japhb/BSON-Simple/actions)

NAME
====

BSON::Simple - Simple codec for the BSON (Binary JSON) serialization format

SYNOPSIS
========

```raku
use BSON::Simple;

# Encode a Raku value to BSON, or vice-versa
my $bson = bson-encode($value);
my $val1 = bson-decode($bson);              # Dies if more data past first decoded document
my $val2 = bson-decode($bson, my $pos = 0); # Updates $pos after decoding first document

# Request warnings when decoding deprecated BSON element types
# (default is to ignore deprecations and handle all known element types)
my $*BSON_SIMPLE_WARN_DEPRECATED = True;
my $bad  = bson-decode($deprecated);     # Warns, but returns decoding anyway
```

DESCRIPTION
===========

BSON::Simple is a trivial implementation of the core functionality of the [BSON serialization format](https://bsonspec.org/), used as the primary data format of the [MongoDB document-oriented database](https://en.wikipedia.org/wiki/MongoDB).

Note that because it is important to retain key order, BSON maps are decoded as ordered hashes using the Hash::Ordered module. Likewise, several BSON types that must maintain a distinction from Raku's standard types are decoded into objects that do the BSON::Simple::Special role.

CAVEATS
=======

  * Does not support the Decimal128 type yet

RELATED
=======

The older [BSON Raku module](https://raku.land/cpan:MARTIMM/BSON) also implements the BSON format. It has a much more detailed API, making it considerably more verbose in actual usage than BSON::Simple. It is also more difficult to adapt as one optional encoding among many for a generic data service (which might serve CSV, JSON, CBOR, and BSON, for example). Finally, its internal design makes it somewhat more difficult to optimize, as it was written before modern buffer handling was added to Raku and before parallelism overhead was fully understood.

On the other hand, that original BSON module has a decade of real world testing and many hundreds of commits behind it, and this module is brand new.

AUTHOR
======

Geoffrey Broadwell <gjb@sonic.net>

COPYRIGHT AND LICENSE
=====================

Copyright 2021 Geoffrey Broadwell

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

