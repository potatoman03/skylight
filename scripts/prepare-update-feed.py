#!/usr/bin/env python3
"""Stage an existing signed Sparkle release for the website's update endpoint."""

import pathlib
import shutil
import sys
import urllib.parse
import xml.etree.ElementTree as ET


def main(feed_path, archive_path, destination):
    feed_path = pathlib.Path(feed_path)
    archive_path = pathlib.Path(archive_path)
    destination = pathlib.Path(destination)
    sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", sparkle)
    feed = ET.parse(feed_path)
    enclosures = feed.findall("./channel/item/enclosure")
    if len(enclosures) != 1:
        raise ValueError("Expected exactly one update enclosure")
    enclosure = enclosures[0]
    if pathlib.PurePosixPath(urllib.parse.urlparse(enclosure.get("url", "")).path).name != archive_path.name:
        raise ValueError("The update feed names a different archive")
    if int(enclosure.get("length", "0")) != archive_path.stat().st_size:
        raise ValueError("The update archive does not match the feed's size")
    if not enclosure.get(f"{{{sparkle}}}edSignature"):
        raise ValueError("The update archive has no Sparkle signature")
    enclosure.set("url", "https://potatoman03.github.io/skylight/" + urllib.parse.quote(archive_path.name))
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(archive_path, destination / archive_path.name)
    feed.write(destination / "appcast.xml", encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: prepare-update-feed.py FEED ARCHIVE DESTINATION")
    main(*sys.argv[1:])
