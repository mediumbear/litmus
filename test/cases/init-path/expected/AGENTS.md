<!-- litmus -->
This project uses Litmus: some source files are tangled from documents that
explain them. Run `tools/litmus guide` before changing any file listed in
build/.litmus/map. After editing a tangled file, carry the change into the
documents with `tools/litmus untangle -o build doc/a.adoc doc/b.md`, and write the prose it asks for.
Tangle with `tools/litmus tangle -o build doc/a.adoc doc/b.md`, and make sure
`tools/litmus check -o build doc/a.adoc doc/b.md` passes before finishing.
<!-- /litmus -->
