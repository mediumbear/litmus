M1 to M5: a Markdown document.

<!-- :litmus-dir: md -->

<!--
… hidden :file: x.txt
-->

… :file: m.txt
```text
… body
```

… body :file: m.txt
~~~~
tilde fence
```
still inside
~~~~

An unlabeled fence is an illustration:

```
… not :file: x.txt
```

include::nothing.md[]
