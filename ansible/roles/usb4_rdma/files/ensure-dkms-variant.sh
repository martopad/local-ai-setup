#!/bin/bash
# ensure-dkms-variant.sh — align the thunderbolt_ibverbs DKMS source
# with the RUNNING kernel's struct tb_nhi shape, in place.
#
# Background: the upstream source (thunderbolt_ibverbs 0.4.0) is
# written for vanilla kernels, where struct tb_nhi carries
# `struct device *dev` and the code tests `dev_is_pci(nhi->dev)` /
# `pdev = to_pci_dev(nhi->dev)`. Gentoo's dist kernels instead expose
# `struct pci_dev *pdev`, and the code there reads
# `dev_is_pci(&nhi->pdev->dev)` / `pdev = nhi->pdev`. Exactly four
# sites in kernel/verbs_dmabuf.c differ. This script detects which
# form the running kernel header declares and which form the source
# currently has, converts if they differ, and prints CHANGED or
# NOCHANGE on stdout (the ansible task keys off that).
set -euo pipefail

PKGNAME="${1:-thunderbolt-ibverbs}"
PKGVER="${2:-0.4.0}"
SRC="/usr/src/${PKGNAME}-${PKGVER}"
DMABUF="${SRC}/kernel/verbs_dmabuf.c"
HDR="/lib/modules/$(uname -r)/build/include/linux/thunderbolt.h"

[ -f "$DMABUF" ] || { echo "ERROR: $DMABUF missing (run the DKMS source bootstrap first)"; exit 2; }
[ -f "$HDR" ] || { echo "ERROR: $HDR missing (kernel headers not installed?)"; exit 2; }

# Which form does the running kernel's header declare?
KERNEL_FORM=$(awk '/struct tb_nhi \{/,/^\};/' "$HDR" | grep -q 'struct pci_dev \*pdev' && echo pdev || echo dev)
# Which form does the source currently have?
SRC_FORM=$(grep -q 'dev_is_pci(&ring->nhi->pdev->dev)' "$DMABUF" && echo pdev || \
           { grep -q 'dev_is_pci(ring->nhi->dev)' "$DMABUF" && echo dev || echo UNKNOWN; })

echo "kernel=$KERNEL_FORM src=$SRC_FORM"

if [ "$KERNEL_FORM" = "$SRC_FORM" ]; then
  echo "NOCHANGE"
  exit 0
fi

# DRY_RUN=1 (ansible check-mode): report what would happen, rewrite nothing.
if [ -n "${DRY_RUN:-}" ]; then
  echo "CHANGED"
  exit 0
fi

case "$SRC_FORM:$KERNEL_FORM" in
  pdev:pdev) exit 0 ;;
  pdev:dev)
    # Gentoo pdev source -> vanilla dev form
    sed -i \
      -e 's/dev_is_pci(&ring->nhi->pdev->dev)/dev_is_pci(ring->nhi->dev)/g' \
      -e 's/pdev = ring->nhi->pdev/pdev = to_pci_dev(ring->nhi->dev)/g' \
      "$DMABUF"
    ;;
  dev:pdev)
    # vanilla dev source -> Gentoo pdev form
    sed -i \
      -e 's/dev_is_pci(ring->nhi->dev)/dev_is_pci(\&ring->nhi->pdev->dev)/g' \
      -e 's/pdev = to_pci_dev(ring->nhi->dev)/pdev = ring->nhi->pdev/g' \
      "$DMABUF"
    ;;
  *)
    echo "ERROR: source form UNKNOWN (neither known variant matches); refusing to rewrite"
    exit 3
    ;;
esac

# Re-derive the form to prove the conversion landed before reporting.
NEW=$(grep -q 'dev_is_pci(&ring->nhi->pdev->dev)' "$DMABUF" && echo pdev || echo dev)
[ "$NEW" = "$KERNEL_FORM" ] || { echo "ERROR: conversion did not reach $KERNEL_FORM"; exit 4; }
echo "CHANGED"
