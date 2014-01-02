TARGETS = ocamlmolex

all: $(TARGETS)

clean:
	ocamlbuild -clean
	rm -rf $(TARGETS)

%.native %.byte: always
	ocamlbuild $@

$(TARGETS):
	cp -f $< $@

.PHONY: always 

ocamlmolex: main.native
