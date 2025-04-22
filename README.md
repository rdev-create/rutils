# rutil: an R library filled with handy wrappers around common R library functions

## [API Documentation](https://rdev-create.github.io/rutils/reference/index.html)

## Things to remember

- Build web content:
  - `brew install pandoc`

## To build a new version

- Increment the Version field in DESCRIPTION file
- Build package:
  - `devtools::document()`
  - `pkgdown::build_site_github_pages()`
  - `devtools::build()`
  - `devtools::check()`
  - commit all changes
  - `git tag -a v0.0.0.9001 -m "rutils v0.0.0.9001"`
  - `git push origin main --tags`

- Users who want to use this library:
  - `devtools::install_github("rdev-create/rutils@v0.0.0.9001")`
  - `library(rutils)`
