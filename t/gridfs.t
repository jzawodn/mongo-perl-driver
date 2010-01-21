use strict;
use warnings;
use Test::More;
use Test::Exception;
use IO::File;
use File::Slurp qw(read_file write_file);

use MongoDB;
use MongoDB::GridFS;
use MongoDB::GridFS::File;
use DateTime;

my $m;
eval {
    my $host = "localhost";
    if (exists $ENV{MONGOD}) {
        $host = $ENV{MONGOD};
    }
    $m = MongoDB::Connection->new(host => $host);
};

if ($@) {
    plan skip_all => $@;
}
else {
    plan tests => 49;
}

my $db = $m->get_database('foo');
my $grid = $db->get_gridfs;
$grid->drop;

# test ctor prefix
is('foo.fs.files', $grid->files->full_name, "no prefix");
is('foo.fs.chunks', $grid->chunks->full_name);

my $fancy_grid = $db->get_gridfs("bar");
is('foo.bar.files', $fancy_grid->files->full_name, "prefix");
is('foo.bar.chunks', $fancy_grid->chunks->full_name);

# test text insert
my $dumb_str = "abc\n\nzyw\n";
my $text_doc = new IO::File("t/input.txt", "r") or die $!;
my $ts = DateTime->now;
my $id = $grid->insert($text_doc);
$text_doc->close;

my $chunk = $grid->chunks->find_one();
is(0, $chunk->{'n'});
is("$id", $chunk->{'files_id'}."", "compare returned id");
is($dumb_str, $chunk->{'data'}, "compare file content");

my $md5 = $db->run_command({"filemd5" => $chunk->{'files_id'}, "root" => "fs"});
my $file = $grid->files->find_one();
ok($file->{'md5'} ne 'd41d8cd98f00b204e9800998ecf8427e', $file->{'md5'});
is($file->{'md5'}, $md5->{'md5'}, $md5->{'md5'});
ok($file->{'uploadDate'}->epoch - $ts->epoch < 10);
is($file->{'chunkSize'}, $MongoDB::GridFS::chunk_size);
is($file->{'length'}, length $dumb_str, "compare file len");
is($chunk->{'files_id'}, $file->{'_id'}, "compare ids");

# test bin insert
my $img = new IO::File("t/img.png", "r") or die $!;
# Windows is dumb
binmode($img);
$id = $grid->insert($img);
my $save_id = $id;
$img->read($dumb_str, 4000000);
$img->close;
my $meta = $grid->files->find_one({'_id' => $save_id});
is($meta->{'length'}, 1292706);

$chunk = $grid->chunks->find_one({'files_id' => $id});
is(0, $chunk->{'n'});
is("$id", $chunk->{'files_id'}."");
my $len = 1048576;
is(substr($dumb_str, 0, $len), substr($chunk->{'data'}, 0, $len), "compare first chunk with file");

$file = $grid->files->find_one({'_id' => $id});
is($file->{'length'}, length $dumb_str, "compare file length");
is($chunk->{'files_id'}, $file->{'_id'}, "compare ids");

# test inserting metadata
$text_doc = new IO::File("t/input.txt", "r") or die $!;
my $now = time;
$id = $grid->insert($text_doc, {"filename" => "t/input.txt", "uploaded" => time, "_id" => 1});
$text_doc->close;

is($id, 1);
# NOT $grid->find_one
$file = $grid->files->find_one({"_id" => 1});
ok($file, "found file");
is($file->{"uploaded"}, $now, "compare ts");
is($file->{"filename"}, "t/input.txt", "compare filename");

# find_one
$file = $grid->find_one({"_id" => 1});
isa_ok($file, 'MongoDB::GridFS::File');
is($file->info->{"uploaded"}, $now, "compare ts");
is($file->info->{"filename"}, "t/input.txt", "compare filename");

#write
my $wfh = IO::File->new("t/output.txt", "+>") or die $!;
my $written = $file->print($wfh);
is($written, length "abc\n\nzyw\n");

my $buf;
$wfh->read($buf, 1000);

is($buf, "abc\n\nzyw\n");

my $wh = IO::File->new("t/outsub.txt", "+>") or die $!;
$written = $file->print($wh, 3, 2);
is($written, 3);

# write bindata
$file = $grid->find_one({'_id' => $save_id});
$wfh = IO::File->new('t/output.png', '+>') or die $!;
$wfh->binmode;
$written = $file->print($wfh);
is($written, $file->info->{'length'}, 'bin file length');

#all
my @list = $grid->all;
is(@list, 3, "three files");
for (my $i=0; $i<3; $i++) {
    isa_ok($list[$i], 'MongoDB::GridFS::File');
}
is($list[0]->info->{'length'}, 9, 'checking lens');
is($list[1]->info->{'length'}, 1292706);
is($list[2]->info->{'length'}, 9);

# remove
is($grid->files->query({"_id" => 1})->has_next, 1, 'pre-remove');
is($grid->chunks->query({"files_id" => 1})->has_next, 1);
$file = $grid->remove({"_id" => 1});
is(int($grid->files->query({"_id" => 1})->has_next), 0, 'post-remove');
is(int($grid->chunks->query({"files_id" => 1})->has_next), 0);

# remove just_one
$grid->drop;
$img = new IO::File("t/img.png", "r") or die $!;
$grid->insert($img, {"filename" => "garbage.png"});
$grid->insert($img, {"filename" => "garbage.png"});

is($grid->files->count, 2);
$grid->remove({'filename' => 'garbage.png'}, 1);
is($grid->files->count, 1, 'remove just one');

unlink 't/output.txt', 't/output.png', 't/outsub.txt';
$grid->drop;


$grid->drop();

my @files = qw( a.txt b.txt c.txt );
my $filecount = 0;
FILELOOP:
for my $f (@files) {
    my $txt = "HELLO" x 1_000_000; # 5MB
    my $l = length($txt);
    
    my $tmpfile = "/tmp/file.$$.tmp";
    write_file( $tmpfile, $txt ) || die $!;
    my $fh = IO::File->new($tmpfile, "r");
    
    $grid->insert( $fh, { filename=>$f } );
    $fh->close() || die $!;
    unlink($tmpfile) || die $!;

    # now, spot check that we can retrieve the file
    my $gridfile = $grid->find_one( { filename => $f } );
    my $info = $gridfile->info();

    is($info->{length}, 5000000, 'length: '.$info->{'length'});
    is($info->{filename}, $f, $info->{'filename'});
}


END {
    if ($db) {
        $db->drop;
    }
}
