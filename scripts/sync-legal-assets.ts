const copies: Record<string, string> = {
  "LICENSE.md": "app/assets/legal/LICENSE.md",
  "LICENSING.md": "app/assets/legal/LICENSING.md",
  "THIRD-PARTY.md": "app/assets/legal/THIRD-PARTY.md",
  "BRAND-ASSETS-LICENSE.md": "app/assets/legal/BRAND-ASSETS-LICENSE.md",
  "SOURCE_OFFER.md": "app/assets/legal/SOURCE_OFFER.md",
  "relay/LICENSE.md": "app/assets/legal/ELASTIC-2.0.md",
};

for (const [source, destination] of Object.entries(copies)) {
  await Bun.write(destination, await Bun.file(source).arrayBuffer());
}

