# Used by "mix format"
[
  # ash's formatter plugins keep the DSL blocks in our test resources shaped
  # the same way ash projects format them.
  import_deps: [:ash],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
