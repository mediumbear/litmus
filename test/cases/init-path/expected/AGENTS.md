<!-- litmus -->
This project uses Litmus: some source files are tangled from documents that
explain them. Run `tools/litmus guide` before changing any file listed in
build/.litmus/map. Tangle with `tools/litmus tangle -o build doc/a.adoc doc/b.md`, and make sure
`tools/litmus check -o build doc/a.adoc doc/b.md` passes before finishing.
<!-- /litmus -->
