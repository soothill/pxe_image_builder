# Makefile for the openSUSE Leap 15.6 Custom ISO Builder

.PHONY: help deps build clean

# Set the default target to 'help'
.DEFAULT_GOAL := help

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  help      Display this help message."
	@echo "  deps      Install the required dependencies for the build."
	@echo "  build     Create the custom openSUse Leap 15.6 ISO."
	@echo "  pxe-setup Configure and start a PXE boot server."
	@echo "  clean     Remove all build artifacts and the final ISO."

deps:
	@echo "Installing dependencies..."
	@sudo ./install_dependencies.sh

build:
	@echo "Building the custom ISO..."
	@sudo ./create_iso.sh

pxe-setup:
	@echo "Setting up the PXE boot server..."
	@sudo ./setup_pxe.sh

clean:
	@echo "Cleaning up the workspace..."
	@sudo rm -rf build openSUSE-Leap-15.6-Custom.iso
