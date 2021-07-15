use v6.d;
use Test;
use BSON::Simple;


#| Convert hex stringification to blob
sub hex2blob(Str:D $hex) is export {
    buf8.new($hex.comb(2).map(*.parse-base(16)))
}


#| Round trip testing to a hex stringification of the BSON blob
multi matches(Mu $value, Str:D $bson) is export {
    matches($value, hex2blob($bson))
}

#| Round trip testing directly to a BSON blob
multi matches(Mu $value, Buf:D $bson) is export {
    subtest "$value.raku() handled correctly", {
        my $as-bson  = bson-encode($value);
        my $as-value = bson-decode($bson);

        is-deeply $as-bson,  $bson,  "bson-encode produces correct blob";
        is-deeply $as-value, $value, "bson-decode produces correct value" if $value  ~~ Any;
        is        $as-value, Mu,     "bson-decode produces correct value" if $value !~~ Any;
    }
}


#| Unidirectional ENcoding testing, matching a hex stringification of the expected BSON blob
multi encodes-to(Mu $value, Str:D $bson) is export {
    encodes-to($value, hex2blob($bson))
}

#| Unidirectional ENcoding testing, matching an expected BSON blob
multi encodes-to(Mu $value, Buf:D $bson) is export {
    my $as-bson = bson-encode($value);
    is-deeply $as-bson, $bson, "bson-encode({$value.raku}) produces correct blob"
}


#| Unidirectional DEcoding testing, from a hex stringification of the actual BSON blob
multi decodes-to(Mu $value, Str:D $bson) is export {
    decodes-to($value, hex2blob($bson))
}

#| Unidirectional DEcoding testing, from an actual BSON blob
multi decodes-to(Mu $value, Buf:D $bson) is export {
    my $as-value = bson-decode($bson);
    my $as-hex   = $bson.map(*.fmt('%02X')).join;

    if $value ~~ Any {
        is-deeply $as-value, $value, "bson-decode($as-hex) produces correct value"
    }
    else {
        is        $as-value, $value, "bson-decode($as-hex) produces correct value"
    }
}
