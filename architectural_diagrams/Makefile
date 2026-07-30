# ==============================================================================
# Makefile for Architectural Diagrams Suite
# Compiles all 10 TikZ Submodule Architectures into Publication PDFs & PNGs
# ==============================================================================

DIAGRAMS = \
	sub01_top_controller \
	sub02_encap_datapath \
	sub03_decap_fo_transform \
	sub04_ntt_mem_banking \
	sub05_butterfly_unit \
	sub06_karatsuba_multiplier \
	sub07_field_alu_accumulator \
	sub08_keccak_f1600_core \
	sub09_hash_sampler_cbd \
	sub10_poly_codecs_compress

export TEXINPUTS := .:./styles:${TEXINPUTS}

.PHONY: all clean pngs $(DIAGRAMS)

all: $(DIAGRAMS) pngs

$(DIAGRAMS): %: %.pdf

%.pdf: %.tex styles/ieee_diagrams.sty
	pdflatex -interaction=nonstopmode $<
	pdflatex -interaction=nonstopmode $<

pngs: $(DIAGRAMS:%=%.png)

%.png: %.pdf
	pdftoppm -png -r 150 -singlefile $< $*

clean:
	rm -f *.aux *.log *.out *.synctex.gz

distclean: clean
	rm -f *.pdf *.png
