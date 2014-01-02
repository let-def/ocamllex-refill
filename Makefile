TARGETS = ocamllex

all: $(TARGETS)

clean:
	ocamlbuild -clean
	rm -rf $(TARGETS)

%.native %.byte: always
	ocamlbuild $@

$(TARGETS):
	cp -f $< $@

.PHONY: always 

ocamllex: main.native
