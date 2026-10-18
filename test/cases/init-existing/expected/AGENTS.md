# Notes

Work carefully.

<!-- litmus -->
This project uses Litmus: some source files are tangled from documents that
explain them. Run `litmus guide` before changing any file listed in
.litmus/map. After editing a tangled file, carry the change into the
documents with `litmus untangle doc/book.adoc`, and write the prose it asks for.
Tangle with `litmus tangle doc/book.adoc`, and make sure
`litmus check doc/book.adoc` passes before finishing.
<!-- /litmus -->
