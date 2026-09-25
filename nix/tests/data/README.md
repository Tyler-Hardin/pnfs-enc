# The benchmark corpus

Ten files of real data, 737 MiB each, byte for byte the originals with the
names changed: `test1.bin` … `test10.bin` were drawn at random from a directory
of real work, and the mapping back to their names is deliberately not in this
repository.

They are float32 volumes out of a reconstruction - mostly NaN and zero, with a
few tens of percent of finite data - which makes them the honest test of what
the data path carries: a 256 KiB unit of them encodes to a median 8.5 KiB and a
mean 24 KiB, against tens of *bytes* for the synthetic `'P'`-repeated files the
suites used before. That is three orders of magnitude more payload a unit, so
the wire, the storage and the codec all stop being free.

The whole 80 MiB subset used for the quick numbers in doc/development.md
compresses 13.2x at zstd -3 and 15.2x at -19, against 30,000x for `'P'`.

The guest sees 737 MiB of each: the raw disk rounds the file to a 4 KiB
boundary and reads stop at the last whole MiB. The files here are the originals,
byte for byte, and the tests compare the client's and the server's digest of the
same file, so the fixture agrees with itself; the tail below a MiB boundary is
all that does not reach a guest.

They are attached to the guests as read-only raw disks - never copied - because
a copy inside a derivation or a VM image would be another 7.3 GB in the store.
`nix/tests/corpus.nix` has the details, and `doc/development.md` has the
measurements.
