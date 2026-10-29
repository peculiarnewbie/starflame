This fixture has its own app configuration and sources, independent of the
examples. Tests copy it into `build/kit-test/` and turn `src/**/*.gleam.in`
into `.gleam` files. The suffix keeps Gleam and gleeunit from compiling or
discovering these app modules as kit test modules.
