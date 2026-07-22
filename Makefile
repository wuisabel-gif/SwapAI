.PHONY: test check install

test:
	./tests/test.sh

check:
	sh -n bin/swapai lib/swapai.sh install.sh tests/test.sh

install:
	./install.sh

