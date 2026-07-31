# ==============================================================================
# Makefile for IEEE Research Paper
# ==============================================================================

PAPER_NAME = main
TEX_SRC    = $(PAPER_NAME).tex
BIB_SRC    = references.bib

# Configure search paths for styles and figures
export TEXINPUTS := .:./styles:./figures:${TEXINPUTS}
export BIBINPUTS := .:${BIBINPUTS}
export BSTINPUTS := .:${BSTINPUTS}

FIGURES_TEX = $(wildcard figures/fig*.tex)
FIGURES_PDF = $(FIGURES_TEX:.tex=.pdf)

.PHONY: all paper clean distclean figures

all: paper

figures: $(FIGURES_PDF)

figures/%.pdf: figures/%.tex
	@echo "[*] Compiling figure $<..."
	@cd figures && pdflatex -interaction=nonstopmode $(notdir $<) > /dev/null

paper: $(PAPER_NAME).pdf

$(PAPER_NAME).pdf: $(FIGURES_PDF) $(TEX_SRC) $(BIB_SRC)
	@mkdir -p figures
	pdflatex -interaction=nonstopmode $(PAPER_NAME).tex
	bibtex $(PAPER_NAME)
	pdflatex -interaction=nonstopmode $(PAPER_NAME).tex
	pdflatex -interaction=nonstopmode $(PAPER_NAME).tex
	@echo "[+] Paper compiled successfully: $(PAPER_NAME).pdf"

clean:
	rm -f $(PAPER_NAME).pdf *.aux *.bbl *.blg *.log *.out *.toc *.nav *.snm *.vrb *.synctex.gz
	rm -f figures/*.aux figures/*.log figures/*.out

distclean: clean
	rm -f figures/*.pdf figures/*.png
