#!/usr/bin/env python3
"""Add (or replace) one release in a Sparkle appcast, keeping older items.

appcast.py APPCAST --version 0.1.0 --build 68 --url URL --ed-signature SIG --length N
           [--notes-url URL] [--notes-file notes.md] [--min-system 14.0] [--title T] [--link L]
"""
import argparse, datetime, html, os, re, sys
import xml.etree.ElementTree as ET

SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SP)
ET.register_namespace("dc", DC)

def md_to_html(md):
    out, in_list = [], False
    for line in md.splitlines():
        s = line.strip()
        if s.startswith(("- ", "* ")):
            if not in_list: out.append("<ul>"); in_list = True
            out.append(f"<li>{html.escape(s[2:])}</li>")
            continue
        if in_list: out.append("</ul>"); in_list = False
        if not s: continue
        m = re.match(r"(#+)\s+(.*)", s)
        out.append(f"<h3>{html.escape(m.group(2))}</h3>" if m else f"<p>{html.escape(s)}</p>")
    if in_list: out.append("</ul>")
    return "\n".join(out)

def main():
    a = argparse.ArgumentParser()
    a.add_argument("appcast"); a.add_argument("--version", required=True); a.add_argument("--build", required=True)
    a.add_argument("--url", required=True); a.add_argument("--ed-signature", required=True); a.add_argument("--length", required=True)
    a.add_argument("--notes-url"); a.add_argument("--notes-file"); a.add_argument("--min-system", default="14.0")
    a.add_argument("--title", default="Flo State"); a.add_argument("--link", default="https://github.com/Altimor/flo-state")
    o = a.parse_args()
    if os.path.exists(o.appcast):
        tree = ET.parse(o.appcast); channel = tree.getroot().find("channel")
    else:
        rss = ET.Element("rss", {"version": "2.0"}); channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = o.title
        ET.SubElement(channel, "link").text = o.link
        ET.SubElement(channel, "description").text = f"{o.title} updates"
        ET.SubElement(channel, "language").text = "en"
        tree = ET.ElementTree(rss)
    for it in channel.findall("item"):  # re-running a release replaces its item
        if it.findtext(f"{{{SP}}}version") == o.build: channel.remove(it)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {o.version}"
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, f"{{{SP}}}version").text = o.build
    ET.SubElement(item, f"{{{SP}}}shortVersionString").text = o.version
    ET.SubElement(item, f"{{{SP}}}minimumSystemVersion").text = o.min_system
    if o.notes_url:
        ET.SubElement(item, f"{{{SP}}}releaseNotesLink").text = o.notes_url
    elif o.notes_file:
        ET.SubElement(item, "description").text = md_to_html(open(o.notes_file).read())
    ET.SubElement(item, "enclosure", {"url": o.url, f"{{{SP}}}edSignature": o.ed_signature,
                                      "length": str(o.length), "type": "application/octet-stream"})
    # newest first, after the channel header
    first = next((i for i, c in enumerate(channel) if c.tag == "item"), len(channel))
    channel.insert(first, item)
    ET.indent(tree, "  ")
    tree.write(o.appcast, encoding="utf-8", xml_declaration=True)
    print(f"appcast: {o.appcast} ({len(channel.findall('item'))} items)")

if __name__ == "__main__":
    main()
