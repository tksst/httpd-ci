use strict;
use warnings FATAL => 'all';

use Apache::Test;
use Apache::TestRequest;
use Apache::TestUtil;

## mod_negotiation test
##
## extra.conf.in:
##
## <IfModule mod_mime.c>
## AddLanguage en .en
## AddLanguage fr .fr
## AddLanguage de .de
## AddLanguage fu .fu
## AddHandler type-map .var
## 
## <IfModule mod_negotiation.c>
## CacheNegotiatedDocs
## <Directory @SERVERROOT@/htdocs/modules/negotiation/en>
## Options +MultiViews
## LanguagePriority en fr de fu
## </Directory>
## <Directory @SERVERROOT@/htdocs/modules/negotiation/de>
## Options +MultiViews
## LanguagePriority de en fr fu
## </Directory>
## <Directory @SERVERROOT@/htdocs/modules/negotiation/fr>
## Options +MultiViews
## LanguagePriority fr en de fu
## </Directory>
## <Directory @SERVERROOT@/htdocs/modules/negotiation/fu>
## Options +MultiViews
## LanguagePriority fu fr en de
## </Directory>
## </IfModule>
## </IfModule>


my ($en, $fr, $de, $fu, $bu) = qw(en fr de fu bu);
my @language = ($en, $fr, $de, $fu);
my $tests = (@language * 3) + (@language * @language * 5) + 7;
my @todo = ();

my $pr_33112_fix_version = '2.2.15';
my $check_pr_33112 = have_min_apache_version($pr_33112_fix_version);
@todo = ($tests) unless $check_pr_33112;

plan tests => $tests, todo => \@todo,
    have_module 'negotiation' && have_cgi && have_module 'mime';

my $actual;

#XXX: this is silly; need a better way to be portable
sub my_chomp {
    $actual =~ s/[\r\n]+$//s;
}

foreach (@language) {

    ## verify that the correct default language content is returned
    $actual = GET_BODY "/modules/negotiation/$_/";
    print "# GET /modules/negotiation/$_/\n";
    my_chomp();
    ok t_cmp($actual, "index.html.$_",
             "Verify correct default language for index.$_.foo");

    $actual = GET_BODY "/modules/negotiation/$_/compressed/";
    print "# GET /modules/negotiation/$_/compressed/\n";
    my_chomp();
    ok t_cmp($actual, "index.html.$_.gz",
             "Verify correct default language for index.$_.foo.gz");

    $actual = GET_BODY "/modules/negotiation/$_/two/index";
    print "# GET /modules/negotiation/$_/two/index\n";
    my_chomp();
    ok t_cmp($actual, "index.$_.html",
             "Verify correct default language for index.$_.html");

    foreach my $ext (@language) {

        ## verify that you can explicitly request all language files.
        my $resp = GET("/modules/negotiation/$_/index.html.$ext");
        print "# GET /modules/negotiation/$_/index.html.$ext\n";
        ok t_cmp($resp->code,
                 200,
                 "Explicitly request $_/index.html.$ext");
        $resp = GET("/modules/negotiation/$_/two/index.$ext.html");
        print "# GET /modules/negotiation/$_/two/index.$ext.html\n";
        ok t_cmp($resp->code,
                 200,
                 "Explicitly request $_/two/index.$ext.html");

        ## verify that even tho there is a default language,
        ## the Accept-Language header is obeyed when present.
        $actual = GET_BODY "/modules/negotiation/$_/",
            'Accept-Language' => $ext;
        print "# GET /modules/negotiation/$_/\n# Accept-Language: $ext\n";
        my_chomp();
        ok t_cmp($actual, "index.html.$ext",
                 "Verify with a default language Accept-Language still obeyed");

        $actual = GET_BODY "/modules/negotiation/$_/compressed/",
            'Accept-Language' => $ext;
        print "# GET /modules/negotiation/$_/compressed/\n# Accept-Language: $ext\n";
        my_chomp();
        ok t_cmp($actual, "index.html.$ext.gz",
                 "Verify with a default language Accept-Language still ".
                   "obeyed (compression on)");

        $actual = GET_BODY "/modules/negotiation/$_/two/index",
            'Accept-Language' => $ext;
        print "# GET /modules/negotiation/$_/two/index\n# Accept-Language: $ext\n";
        my_chomp();
        ok t_cmp($actual, "index.$ext.html",
                 "Verify with a default language Accept-Language still obeyed");

    }
}

## more complex requests ##

## 'fu' has a quality rating of 0.9 which is higher than the rest
## we expect Apache to return the 'fu' content.
$actual = GET_BODY "/modules/negotiation/$en/",
    'Accept-Language' => "$en; q=0.1, $fr; q=0.4, $fu; q=0.9, $de; q=0.2";
print "# GET /modules/negotiation/$en/\n# Accept-Language: $en; q=0.1, $fr; q=0.4, $fu; q=0.9, $de; q=0.2\n";
my_chomp();
ok t_cmp($actual, "index.html.$fu",
         "fu has a higher quality rating, so we expect fu");

$actual = GET_BODY "/modules/negotiation/$en/two/index",
    'Accept-Language' => "$en; q=0.1, $fr; q=0.4, $fu; q=0.9, $de; q=0.2";
print "# GET /modules/negotiation/$en/two/index\n# Accept-Language: $en; q=0.1, $fr; q=0.4, $fu; q=0.9, $de; q=0.2\n";
my_chomp();
ok t_cmp($actual, "index.$fu.html",
         "fu has a higher quality rating, so we expect fu");

$actual = GET_BODY "/modules/negotiation/$en/compressed/",
    'Accept-Language' => "$en; q=0.1, $fr; q=0.4, $fu; q=0.9, $de; q=0.2";
print "# GET /modules/negotiation/$en/compressed/\n# Accept-Language: $en; q=0.1, $fr; q=0.4, $fu; q=0.9, $de; q=0.2\n";
my_chomp();
ok t_cmp($actual, "index.html.$fu.gz",
         "fu has a higher quality rating, so we expect fu");

## 'bu' has the highest quality rating, but is non-existant,
## so we expect the next highest rated 'fr' content to be returned.
$actual = GET_BODY "/modules/negotiation/$en/",
    'Accept-Language' => "$en; q=0.1, $fr; q=0.4, $bu; q=1.0";
print "# GET /modules/negotiation/$en/\n# Accept-Language: $en; q=0.1, $fr; q=0.4, $bu; q=1.0\n";
my_chomp();
ok t_cmp($actual, "index.html.$fr",
         "bu has the highest quality but is non-existant, so fr is next best");

$actual = GET_BODY "/modules/negotiation/$en/two/index",
    'Accept-Language' => "$en; q=0.1, $fr; q=0.4, $bu; q=1.0";
print "# GET /modules/negotiation/$en/two/index\n# Accept-Language: $en; q=0.1, $fr; q=0.4, $bu; q=1.0\n";
my_chomp();
ok t_cmp($actual, "index.$fr.html",
         "bu has the highest quality but is non-existant, so fr is next best");

$actual = GET_BODY "/modules/negotiation/$en/compressed/",
    'Accept-Language' => "$en; q=0.1, $fr; q=0.4, $bu; q=1.0";
print "# GET /modules/negotiation/$en/compressed/\n# Accept-Language: $en; q=0.1, $fr; q=0.4, $bu; q=1.0\n";
my_chomp();
ok t_cmp($actual, "index.html.$fr.gz",
         "bu has the highest quality but is non-existant, so fr is next best");

# PR 33112
$actual = GET_BODY "/modules/negotiation/query/test?foo";
print "# GET /modules/negotiation/query/test?foo\n";
my_chomp();
ok t_cmp($actual, "QUERY_STRING --> foo",
         "The type map gives the script the highest quality;"
         . "\nthe request included a query string");
if (!$check_pr_33112) {
    print STDERR "TODO: Fix for query string preservation after content negotiation (PR 33112 not fixed before $pr_33112_fix_version).\n";
}
