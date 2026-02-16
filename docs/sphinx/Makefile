html:
	sphinx-build -b html . _build/html
	cp _build/html/index.html ../
	cp -r _build/html/_static ../
	cp _build/html/search.html ../
	cp _build/html/searchindex.js ../
	cp _build/html/genindex.html ../
	cp -r _build/html/releases ../

clean:
	rm -rf _build

.PHONY: html clean
