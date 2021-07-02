unit class BSON::Simple:auth<zef:japhb>:api<0>:ver<0.0.1>;


enum BSONType (
    BSON_Double      => 1,
    BSON_String      => 2,
    BSON_Document    => 3,
    BSON_Array       => 4,
    BSON_Binary      => 5,
    BSON_Undefined   => 6,  # Deprecated
    BSON_ObjectId    => 7,
    BSON_Boolean     => 8,
    BSON_Datetime    => 9,
    BSON_Null        => 10,
    BSON_Regex       => 11,
    BSON_DBPointer   => 12, # Deprecated
    BSON_JavaScript  => 13,
    BSON_Symbol      => 14, # Deprecated
    BSON_ScopedJS    => 15, # Deprecated
    BSON_int32       => 16,
    BSON_Timestamp   => 17,
    BSON_int64       => 18,
    BSON_decimal128  => 19,
    BSON_MaxKey      => 127,
    BSON_MinKey      => 255,
);

enum BSONSubtype (
    BSON_Generic     => 0,
    BSON_Function    => 1,
    BSON_Binary_Old  => 2,
    BSON_UUID_Old    => 3,
    BSON_UUID        => 4,
    BSON_MD5         => 5,
    BSON_Encrypted   => 6,
    BSON_UserDefined => 128,
);


# Encode a Raku data structure into BSON
multi bson-encode(Mu $value) is export {
    bson-encode($value, my $pos = 0)
}

# Encode a Raku data structure into BSON, starting at buffer position $pos
multi bson-encode(Mu $value, Int:D $pos is rw, Buf:D $buf = buf8.new) is export {
    # Write a C-style NUL-terminated UTF-8 encoded string
    my &write-cstring = -> $string {
        my $encoded = $string.encode;
        my $bytes   = $encoded.elems;

        $buf.splice($pos, $bytes, $encoded);
        $pos += $bytes;
        $buf.write-uint8($pos++, 0);
    }

    # Write a UTF-8 encoded string with *both* a leading byte count and trailing NUL
    my &write-string = -> $string {
        my $encoded = $string.encode;
        my $bytes   = $encoded.elems;

        # Write $bytes + 1 here to include trailing NUL
        $buf.write-int32($pos, $bytes + 1, LittleEndian);
        $pos += 4;

        $buf.splice($pos, $bytes, $encoded);
        $pos += $bytes;
        $buf.write-uint8($pos++, 0);
    }

    # Write a (possibly subtyped) binary blob
    my &write-binary = -> $blob, $subtype = BSON_Generic {
        my $bytes = $blob.elems;
        $buf.write-int32($pos, $bytes, LittleEndian);
        $pos += 4;

        $buf.write-uint8($pos++, $subtype);

        $buf.splice($pos, $bytes, $blob);
        $pos += $bytes;
    }

    # Write a document, given an iterable of key => value pairs
    my &write-document = -> $pairs {
        # Save location of length field; we'll need to backfill it later
        my $len-pos = $pos;
        $buf.write-int32($pos, 0, LittleEndian);
        $pos += 4;

        # Write elements in *iteration order* (allowing arrays and ordered hashes)
        encode-element(~.key, .value) for $pairs;

        # Trailing NUL byte
        $buf.write-uint8($pos++, 0);

        # Fix up length field (*includes* NUL and this byte count field)
        my $len = $pos - $len-pos;
        $buf.write-int32($len-pos, $len, LittleEndian);
    }

    # Encode a general document element with e_name (key) $key
    my sub encode-element(Str:D $key, Mu $value) {
        with $value {
            when Numeric {
                when Bool {
                    $buf.write-uint8($pos++, BSON_Boolean);
                    write-cstring($key);
                    $buf.write-uint8($pos++, +$_);
                }
                when Int {
                    if -2147483648 <= $_ <= 2147483647 {
                        $buf.write-uint8($pos++, BSON_int32);
                        write-cstring($key);
                        $buf.write-int32($pos, $_, LittleEndian);
                        $pos += 4;
                    }
                    else {
                        $buf.write-uint8($pos++, BSON_int64);
                        write-cstring($key);
                        $buf.write-int64($pos, $_, LittleEndian);
                        $pos += 8;
                    }
                }
                when Num {
                    $buf.write-uint8($pos++, BSON_Double);
                    write-cstring($key);
                    $buf.write-num64($pos, $_, LittleEndian);
                    $pos += 8;
                }
                when Instant {
                    $buf.write-uint8($pos++, BSON_Datetime);
                    write-cstring($key);
                    $buf.write-int64($pos, ($_ * 1000).Int, LittleEndian);
                    $pos += 8;
                }
                when Real {
                    encode-element($key, .Num);
                }
                default {
                    die "Don't know how to encode a {$value.^name}";
                }
            }
            when Stringy {
                when Str {
                    $buf.write-uint8($pos++, BSON_String);
                    write-cstring($key);
                    write-string($_);
                }
                when Blob {
                    $buf.write-uint8($pos++, BSON_Binary);
                    write-cstring($key);
                    write-binary($_);
                }
                default {
                    die "Don't know how to encode a {$value.^name}";
                }
            }
            when Associative {
                $buf.write-uint8($pos++, BSON_Document);
                write-cstring($key);
                write-document(.pairs);
            }
            when Positional {
                $buf.write-uint8($pos++, BSON_Array);
                write-cstring($key);
                write-document(.pairs);
            }
            when Dateish {
                encode-element($key, .DateTime.Instant);
            }
        }
        # Undefined values
        else {
            # Any:U is BSON null, other Mu:U is BSON undefined
            $buf.write-uint8($pos++, $value ~~ Any ?? BSON_Null !! BSON_Undefined);
            write-cstring($key);
        }
    }

    # Mu doesn't have a pairs method, so just treat a raw Mu as an empty document
    write-document(($value ~~ Any ?? $value !! Empty).pairs);
}


# Decode a BSON document into native Raku structures
multi bson-decode(Blob:D $bson) is export {
    bson-decode($bson, my $pos = 0)
}

# Decode a BSON document into native Raku structures, starting from buffer position $pos
multi bson-decode(Blob:D $bson, Int:D $pos is rw) is export {
}


=begin pod

=head1 NAME

BSON::Simple - Simple codec for the BSON (Binary JSON) serialization format


=head1 SYNOPSIS

=begin code :lang<raku>

use BSON::Simple;

# Encode a Raku value to BSON, or vice-versa
my $bson = bson-encode($value);
my $val  = bson-decode($bson);

=end code


=head1 DESCRIPTION

BSON::Simple is a trivial implementation of the core functionality of the
L<BSON serialization format|https://bsonspec.org/>,
used as the primary data format of the
L<MongoDB document-oriented database|https://en.wikipedia.org/wiki/MongoDB>.

Note that because it is important to retain key order, BSON maps are decoded
as ordered hashes using the XXXX module.


=head1 RELATED

The older L<BSON Raku module|https://raku.land/cpan:MARTIMM/BSON> also
implements the BSON format.  It has a much more detailed API, making it
considerably more verbose in actual usage than BSON::Simple.  It is also
more difficult to adapt as one optional encoding among many for a generic
data service (which might serve CSV, JSON, CBOR, and BSON, for example).
Finally, its internal design makes it somewhat more difficult to optimize,
as it was written before modern buffer handling was added to Raku and before
parallelism overhead was fully understood.

On the other hand, that original BSON module has a decade of real world testing
and many hundreds of commits behind it, and this module is brand new.


=head1 AUTHOR

Geoffrey Broadwell <gjb@sonic.net>


=head1 COPYRIGHT AND LICENSE

Copyright 2021 Geoffrey Broadwell

This library is free software; you can redistribute it and/or modify it under
the Artistic License 2.0.

=end pod
