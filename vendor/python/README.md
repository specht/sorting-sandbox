# Vendored Python tools

Pure-Python packages used by `languages/python/sandbox_daemon.py`, so that a
classroom computer needs nothing but a Python 3.10+ interpreter. They are never
imported by student code or by the worker that runs it.

| Package | Version | Source | Used for |
| --- | --- | --- | --- |
| black (+ blib2to3) | 26.10.1 | github.com/psf/black | Format button |
| click | 8.5.0 | github.com/pallets/click | dependency of black |
| mypy_extensions | 1.1.0 | github.com/python/mypy_extensions | dependency of black |
| packaging | 26.3 | github.com/pypa/packaging | dependency of black |
| pathspec | 1.1.1 | github.com/cpburnz/python-pathspec | dependency of black |
| platformdirs | 4.13.0 | github.com/tox-dev/platformdirs | dependency of black |
| pytokens | 0.4.1 | github.com/tusharsadhwani/pytokens | dependency of black |
| tomli | 2.5.0 | github.com/hukkin/tomli | dependency of black (Python 3.10) |
| typing_extensions | 4.16.0 | github.com/python/typing_extensions | dependency of black (Python 3.10) |
| pyflakes | 4.0.3 | github.com/PyCQA/pyflakes | undefined names etc. when building |

Each directory is the package's source tree at the release tag, without
tests. `_black_version.py` and `platformdirs/version.py` are normally written
by the build backend and were added by hand. The licenses are in `LICENSES/`.

To update a package, replace its directory with the new release's source and
run `./check`.
