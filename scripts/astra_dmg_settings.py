"""Finder layout for the notarized Astra Browser installer."""

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
window_rect = ((180, 120), (820, 478))
icon_size = 128
text_size = 15
icon_locations = {"Astra Browser.app": (205, 238), "Applications": (615, 238)}
format = "UDZO"
