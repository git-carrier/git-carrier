.POSIX:

.PHONY: lint test check

all: check

lint:
	shellcheck --severity=style git-carrier.bash
	shfmt -d git-carrier.bash tests/helpers.bash
	! LC_ALL=C grep -Han "$$(printf '[\200-\377]')" \
	  git-carrier.bash tests/helpers.bash \
	  README.md docs/hangar-format.txt

test:
	bats -r tests

check: lint test
