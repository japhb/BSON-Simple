unit module BSON::Simple:auth<zef:japhb>:api<0>:ver<0.0.1>;


use Base64::Native;
use Hash::Ordered;


enum BSONType (
    BSON_Double      => 1,
    BSON_String      => 2,
    BSON_Document    => 3,
    BSON_Array       => 4,
    BSON_Binary      => 5,
    BSON_Undefined   => 6,  # Deprecated
    BSON_ObjectID    => 7,
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


PROCESS::<$BSON_SIMPLE_WARN_DEPRECATED> = False;
PROCESS::<$BSON_SIMPLE_PLAIN_HASHES>    = False;
PROCESS::<$BSON_SIMPLE_PLAIN_BLOBS>     = False;


# Precache a utf8 encoder, since we'll be doing it a LOT
my $utf8-encoder = Encoding::Registry.find("utf8").encoder;


# Simple converter utility: hex string to binary buf
sub hex-decode(Str:D $hex, $buf-type = buf8) is export {
    $buf-type.new($hex.comb(2).map(*.parse-base(16)))
}


# Special types
my role Special {}

my class SimpleSpecial does Special {
    has $.name is required;
}
constant MinKey is export = SimpleSpecial.new(name => 'MinKey');
constant MaxKey is export = SimpleSpecial.new(name => 'MaxKey');

class ObjectID does Special {
    has Blob $.id;

    multi method new(Str:D $hex) {
        self.bless(id => hex-decode($hex))
    }
}

class JSCode does Special {
    has Str:D $.code is required;
}

class ScopedJS is JSCode {
    has %.scope;
}

class Binary does Special {
    has uint8 $.subtype;
    has Blob  $.content;

    multi method new(Int:D $subtype, Str:D :$hex) {
        self.bless(:$subtype, content => hex-decode($hex))
    }

    multi method new(Int:D $subtype, Str:D :$base64) {
        self.bless(:$subtype, content => base64-decode($base64))
    }
}

class Timestamp does Special {
    has uint32 $.i;
    has uint32 $.t;
}

class PCRE_Regex does Special {
    has Str:D $.pattern is required;
    has Str:D $.options is required;
}

class Int32  is Int does Special { }
class Int64  is Int does Special { }
class Symbol is Str does Special { }

class DBPointer does Special {
    has Str:D      $.ref is required;
    has ObjectID:D $.oid is required;
}


# Encode a Raku data structure into BSON
multi bson-encode(Mu $value) is export {
    bson-encode($value, my $pos = 0)
}

# Encode a Raku data structure into BSON, starting at buffer position $pos
multi bson-encode(Mu $value, Int:D $pos is rw, Buf:D $buf = buf8.new) is export {
    # Write a C-style NUL-terminated UTF-8 encoded string
    my &write-cstring = -> \string {
        my $encoded := $utf8-encoder.encode-chars(string);
        my $bytes    = $encoded.elems;

        $buf.splice($pos, $bytes, $encoded);
        $pos += $bytes;
        $buf.write-uint8($pos++, 0);
    }

    # Write a UTF-8 encoded string with *both* a leading byte count and trailing NUL
    my &write-string = -> \string {
        my $encoded := $utf8-encoder.encode-chars(string);
        my $bytes    = $encoded.elems;

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

        if $subtype == BSON_Binary_Old {
            $buf.write-int32($pos, $bytes + 4, LittleEndian);
            $pos += 4;
            $buf.write-uint8($pos++, $subtype);
            $buf.write-int32($pos, $bytes, LittleEndian);
            $pos += 4;
        }
        else {
            $buf.write-int32($pos, $bytes, LittleEndian);
            $pos += 4;
            $buf.write-uint8($pos++, $subtype);
        }

        $buf.splice($pos, $bytes, $blob);
        $pos += $bytes;
    }

    # Write a document, given an iterable of key => value pairs
    my &write-document = -> \pairs {
        # Save location of length field; we'll need to backfill it later
        my $len-pos = $pos;
        $buf.write-int32($pos, 0, LittleEndian);
        $pos += 4;

        # Write elements in *iteration order* (allowing arrays and ordered hashes)
        encode-element(~.key, .value) for pairs;

        # Trailing NUL byte
        $buf.write-uint8($pos++, 0);

        # Fix up length field (*includes* NUL and this byte count field)
        my $len = $pos - $len-pos;
        $buf.write-int32($len-pos, $len, LittleEndian);
    }

    # Write an array document, given a Positional
    my &write-array = -> @array {
        # Save location of length field; we'll need to backfill it later
        my $len-pos = $pos;
        $buf.write-int32($pos, 0, LittleEndian);
        $pos += 4;

        # Write elements with stringified index as key
        my int $elems = @array.elems;
        my int $i     = 0;
        encode-element(~$i, @array.AT-POS($i++)) while $i < $elems;

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
                    when Int32 {
                        $buf.write-uint8($pos++, BSON_int32);
                        write-cstring($key);
                        $buf.write-int32($pos, $_, LittleEndian);
                        $pos += 4;
                    }
                    when Int64 {
                        $buf.write-uint8($pos++, BSON_int64);
                        write-cstring($key);
                        $buf.write-int64($pos, $_, LittleEndian);
                        $pos += 8;
                    }
                    default {
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
                    my $ms = (.to-posix[0] * 1000).Int;
                    $buf.write-int64($pos, $ms, LittleEndian);
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
                when Symbol {
                    $buf.write-uint8($pos++, BSON_Symbol);
                    write-cstring($key);
                    write-string($_);
                }
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
                write-array($_);
            }
            when Dateish {
                encode-element($key, .DateTime.Instant);
            }
            when Special {
                when MinKey {
                    $buf.write-uint8($pos++, BSON_MinKey);
                    write-cstring($key);
                }
                when MaxKey {
                    $buf.write-uint8($pos++, BSON_MaxKey);
                    write-cstring($key);
                }
                when ObjectID {
                    $buf.write-uint8($pos++, BSON_ObjectID);
                    write-cstring($key);
                    my $bytes = .id.elems;
                    $buf.splice($pos, $bytes, .id);
                    $pos += $bytes;
                }
                when ScopedJS {
                    $buf.write-uint8($pos++, BSON_ScopedJS);
                    write-cstring($key);

                    # Save location of length field; we'll need to backfill it later
                    my $len-pos = $pos;
                    $buf.write-int32($pos, 0, LittleEndian);
                    $pos += 4;

                    write-string(.code);
                    write-document(.scope.pairs);

                    # Fix up length field (*includes* this byte count field)
                    my $len = $pos - $len-pos;
                    $buf.write-int32($len-pos, $len, LittleEndian);
                }
                when JSCode {
                    $buf.write-uint8($pos++, BSON_JavaScript);
                    write-cstring($key);
                    write-string(.code);
                }
                when Binary {
                    $buf.write-uint8($pos++, BSON_Binary);
                    write-cstring($key);
                    write-binary(.content, .subtype);
                }
                when Timestamp {
                    $buf.write-uint8($pos++, BSON_Timestamp);
                    write-cstring($key);
                    $buf.write-uint32($pos, .i, LittleEndian);
                    $pos += 4;
                    $buf.write-uint32($pos, .t, LittleEndian);
                    $pos += 4;
                }
                when PCRE_Regex {
                    $buf.write-uint8($pos++, BSON_Regex);
                    write-cstring($key);
                    write-cstring(.pattern);
                    write-cstring(.options.comb.sort.join);
                }
                when DBPointer {
                    $buf.write-uint8($pos++, BSON_DBPointer);
                    write-cstring($key);
                    write-string(.ref);
                    my $bytes = .oid.id.elems;
                    $buf.splice($pos, $bytes, .oid.id);
                    $pos += $bytes;
                }
                default {
                    die "Don't know how to encode a {$value.^name}";
                }
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


# Decode a single BSON document into native Raku structures
multi bson-decode(Blob:D $bson) is export {
    my $value := bson-decode($bson, my $pos = 0);
    if $pos < $bson.bytes {
        die "Extra data after decoded value";
    }
    $value
}

# Decode the next BSON document into native Raku structures,
# starting from buffer position $pos
multi bson-decode(Blob:D $bson, Int:D $pos is rw) is export {
    my $plain-hashes = $*BSON_SIMPLE_PLAIN_HASHES;
    my $plain-blobs  = $*BSON_SIMPLE_PLAIN_BLOBS;

    my &read-cstring = -> {
        my $p = $pos;
        ++$p while $bson[$p];

        my $string = $bson.subbuf($pos, $p - $pos).decode;
        $pos = $p + 1;

        $string
    }

    my &read-string = -> {
        my $bytes = $bson.read-int32($pos, LittleEndian);
        $pos += 4;
        die "Invalid string length $bytes" if $bytes < 1 || $pos + $bytes > $bson.elems;
        die "Invalid string terminator"    if $bson.read-uint8($pos + $bytes - 1) != 0;

        my $string = $bson.subbuf($pos, $bytes - 1).decode;
        $pos += $bytes;

        $string
    }

    my &read-binary = -> {
        my $bytes = $bson.read-int32($pos, LittleEndian);
        $pos += 4;
        my $subtype = $bson.read-uint8($pos++);

        if $subtype == BSON_Binary_Old {
            my $orig = $bytes;
            $bytes = $bson.read-int32($pos, LittleEndian);
            $pos += 4;
            die "Mismatch in old binary sizes" unless $bytes == $orig - 4;
        }

        my $blob = $bson.subbuf($pos, $bytes);
        $pos += $bytes;

        ($subtype, $blob)
    }

    my sub decode-document(Bool :$as-array) {
        # Check document size isn't impossible
        my $start = $pos;
        my $len = $bson.read-int32($pos, LittleEndian);
        die "Document too short" if $len < 5 || $pos + $len > $bson.elems;
        $pos += 4;

        # Look for elements
        if $as-array {
            my @array;
            while $bson.read-uint8($pos++) -> $type {
                # NOTE: Official test suite requires array keys to be *ignored*
                my $pair = decode-element($type);
                @array.push: $pair.value;
            }
            die "Incorrect array length" unless $pos == $start + $len;
            @array
        }
        elsif $plain-hashes {
            my %hash;
            while $bson.read-uint8($pos++) -> $type {
                my $pair = decode-element($type);
                # XXXX: Does not detect key collisions
                %hash{$pair.key} = $pair.value;
            }
            die "Incorrect document length" unless $pos == $start + $len;
            %hash
        }
        else {
            my %hash is Hash::Ordered;
            while $bson.read-uint8($pos++) -> $type {
                my $pair = decode-element($type);
                # XXXX: Does not detect key collisions
                %hash{$pair.key} = $pair.value;
            }
            die "Incorrect document length" unless $pos == $start + $len;
            %hash
        }
    }

    my sub warn-deprecated($type) {
        warn "Deprecated BSON type $type at pos $pos"
        if $*BSON_SIMPLE_WARN_DEPRECATED;
    }

    my Mu $value;
    my @decoders =
        {;},
        { # BSON_Double
            $value = $bson.read-num64($pos, LittleEndian);
            $pos  += 8;
        },
        { # BSON_String
            $value = read-string;
        },
        { # BSON_Document
            $value = decode-document;
        },
        { # BSON_Array
            $value = decode-document :as-array;
        },
        { # BSON_Binary
            my ($subtype, $content) = read-binary;
            $value = $plain-blobs && $subtype == 0
                     ?? $content
                     !! Binary.new(:$subtype, :$content);
        },
        { # BSON_Undefined
            warn-deprecated(BSON_Undefined);
            $value = Mu;
        },
        { # BSON_ObjectID
            $value = ObjectID.new(id => $bson.subbuf($pos, 12));
            $pos  += 12;
        },
        { # BSON_Boolean
            my $bool = $bson.read-uint8($pos++);
            die "Invalid boolean value '$bool'" unless 0 <= $bool <= 1;
            $value = so $bool;
        },
        { # BSON_Datetime
            my $ms = $bson.read-int64($pos, LittleEndian);
            $value = Instant.from-posix($ms / 1000);
            $pos  += 8;
        },
        { # BSON_Null
            $value = Any;
        },
        { # BSON_Regex
            my $pattern = read-cstring;
            my $options = read-cstring().comb.sort.join;
            $options ~~ /^ <[gilmsux]>* $/ or die "Invalid regex options";
            $value = PCRE_Regex.new(:$pattern, :$options);
        },
        { # BSON_DBPointer
            warn-deprecated(BSON_DBPointer);
            my $ref = read-string;
            my $oid = ObjectID.new(:id($bson.subbuf($pos, 12)));
            $pos  += 12;
            $value = DBPointer.new(:$ref, :$oid);
        },
        { # BSON_JavaScript
            $value = JSCode.new(code => read-string);
        },
        { # BSON_Symbol
            warn-deprecated(BSON_Symbol);
            $value = Symbol(read-string);
        },
        { # BSON_ScopedJS
            warn-deprecated(BSON_ScopedJS);
            my $len-pos = $pos;
            my $len     = $bson.read-int32($pos, LittleEndian);
            $pos       += 4;

            my $code    = read-string;
            my $scope   = decode-document;

            die "Wrong ScopedJS length" unless $len == $pos - $len-pos;

            $value = ScopedJS.new(:$code, :$scope);
        },
        { # BSON_int32
            $value = $bson.read-int32($pos, LittleEndian);
            $pos  += 4;
        },
        { # BSON_Timestamp
            my $i  = $bson.read-uint32($pos, LittleEndian);
            $pos  += 4;
            my $t  = $bson.read-uint32($pos, LittleEndian);
            $pos  += 4;
            $value = Timestamp.new(:$i, :$t);
        },
        { # BSON_int64
            $value = Int64.new($bson.read-int64($pos, LittleEndian));
            $pos  += 8;
        },
        { # BSON_decimal128
            ...
        },
    ;


    my sub decode-element($type) {
        my Str:D $key = read-cstring;

        my &decoder := @decoders[$type] // {
            given $type {
                when BSON_MinKey {
                    $value = MinKey;
                }
                when BSON_MaxKey {
                    $value = MaxKey;
                }
                default {
                    die "Unknown BSON type $type";
                }
            }
        }

        decoder();
        $key => $value
    }

    decode-document;
}


=begin pod

=head1 NAME

BSON::Simple - Simple codec for the BSON (Binary JSON) serialization format


=head1 SYNOPSIS

=begin code :lang<raku>

use BSON::Simple;

# Encode a Raku value to BSON, or vice-versa
my $bson = bson-encode($value);
my $val1 = bson-decode($bson);              # Dies if more data past first decoded document
my $val2 = bson-decode($bson, my $pos = 0); # Updates $pos after decoding first document

# Request warnings when decoding deprecated BSON element types
# (default is to ignore deprecations and handle all known element types)
my $*BSON_SIMPLE_WARN_DEPRECATED = True;
my $bad  = bson-decode($deprecated);     # Warns, but returns decoding anyway

# Decode into default Raku Hash and Blob types, instead of ordered hashes
# and wrapped BSON::Simple::Binary objects
my $*BSON_SIMPLE_PLAIN_HASHES = True;
my $*BSON_SIMPLE_PLAIN_BLOBS  = True;
my $simple = bson-decode($bson);


=end code


=head1 DESCRIPTION

BSON::Simple is a trivial implementation of the core functionality of the
L<BSON serialization format|https://bsonspec.org/>,
used as the primary data format of the
L<MongoDB document-oriented database|https://en.wikipedia.org/wiki/MongoDB>.

Note that because it is important to retain key order, BSON maps are decoded as
ordered hashes using the Hash::Ordered module.  Likewise, several BSON types
that must maintain a distinction from Raku's standard types are decoded into
objects that do the BSON::Simple::Special role.

If you would prefer to decode into standard (unordered) Raku hashes, you can
set the C<$*BSON_SIMPLE_PLAIN_HASHES> dynamic variable to C<True>.  Likewise,
if you would prefer to decode default-subtype Binary fields into plain Raku
C<Blob> objects (rather than wrapped into a C<BSON::Simple::Binary> object),
set the C<$*BSON_SIMPLE_PLAIN_BLOBS> dynamic variable to C<True>.


=head1 CAVEATS

=item Does not support the Decimal128 type yet


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
