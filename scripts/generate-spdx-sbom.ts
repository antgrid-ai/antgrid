import { $ } from "bun";
import { licenseForPath } from "./license-map";

const [output = "antgrid.spdx.json", tag = "dev", revision = "unknown"] =
  process.argv.slice(2);
const files = (await $`git ls-files --cached`.text()).split(/\r?\n/).filter(Boolean);

const documentNamespace =
  `https://github.com/antgrid-ai/antgrid/releases/${encodeURIComponent(tag)}/spdx/${revision}`;

const componentDefinitions = [
  ["antgrid-integrations", "SPDXRef-Package-Integrations", "bridge/integrations/", "MPL-2.0"],
  ["antgrid-bridge", "SPDXRef-Package-Bridge", "bridge/", "MPL-2.0"],
  ["antgrid-app", "SPDXRef-Package-App", "app/", "MPL-2.0"],
  ["antgrid-evals", "SPDXRef-Package-Evals", "evals/", "MPL-2.0"],
  ["antgrid-agents", "SPDXRef-Package-Agents", "packages/antgrid-agents/", "MPL-2.0"],
  ["antgrid-eval-client", "SPDXRef-Package-EvalClient", "packages/antgrid_eval_client/", "MPL-2.0"],
  ["antgrid-relay-client", "SPDXRef-Package-RelayClient", "packages/antgrid_relay_client/", "MPL-2.0"],
  ["antgrid-wire", "SPDXRef-Package-Wire", "packages/antgrid-wire/", "MPL-2.0"],
  ["antgrid-relay", "SPDXRef-Package-Relay", "relay/", "LicenseRef-Elastic-2.0"],
  ["antgrid-web", "SPDXRef-Package-Web", "web/", "LicenseRef-Elastic-2.0"],
  ["antgrid-site", "SPDXRef-Package-Site", "site/", "MPL-2.0"],
  ["antgrid-aspire", "SPDXRef-Package-Aspire", "aspire/", "MPL-2.0"],
  ["antgrid-root-sources", "SPDXRef-Package-Root", "", "MPL-2.0"],
] as const;

function componentFor(path: string): (typeof componentDefinitions)[number] {
  return componentDefinitions.find(([, , prefix]) => prefix && path.startsWith(prefix)) ??
    componentDefinitions.at(-1)!;
}

const spdxFiles: Array<{
  fileName: string;
  SPDXID: string;
  checksums: Array<{ algorithm: string; checksumValue: string }>;
  licenseConcluded: string;
  licenseInfoInFiles: string[];
  copyrightText: string;
}> = [];
const filesByPackage = new Map<string, typeof spdxFiles>();
for (const path of files) {
  const data = await Bun.file(path).arrayBuffer();
  const hash = new Bun.CryptoHasher("sha1").update(data).digest("hex");
  const id = `SPDXRef-File-${spdxFiles.length + 1}`;
  spdxFiles.push({
    fileName: `./${path}`,
    SPDXID: id,
    checksums: [{ algorithm: "SHA1", checksumValue: hash }],
    licenseConcluded: licenseForPath(path),
    licenseInfoInFiles: [licenseForPath(path)],
    copyrightText: "NOASSERTION",
  });
  const packageId = componentFor(path)[1];
  const owned = filesByPackage.get(packageId) ?? [];
  owned.push(spdxFiles.at(-1)!);
  filesByPackage.set(packageId, owned);
}

const packages = componentDefinitions.map(([name, SPDXID, , licenseDeclared]) => {
  const componentFiles = filesByPackage.get(SPDXID) ?? [];
  const licenseInfoFromFiles = [...new Set(
    componentFiles.map((file) => file.licenseConcluded),
  )].sort();
  return {
    name,
    SPDXID,
    versionInfo: tag,
    downloadLocation: `https://github.com/antgrid-ai/antgrid/tree/${revision}`,
    filesAnalyzed: true,
    packageVerificationCode: {
      packageVerificationCodeValue: new Bun.CryptoHasher("sha1")
        .update(
          componentFiles
            .map((file) => file.checksums[0]!.checksumValue)
            .sort()
            .join(""),
        )
        .digest("hex"),
    },
    licenseConcluded: licenseInfoFromFiles.join(" AND ") || "NOASSERTION",
    licenseDeclared,
    licenseInfoFromFiles,
    copyrightText: "Copyright 2026 Radha AI Products",
  };
});

packages.unshift({
  name: "Antgrid repository",
  SPDXID: "SPDXRef-Package-Antgrid",
  versionInfo: tag,
  downloadLocation: `https://github.com/antgrid-ai/antgrid/tree/${revision}`,
  filesAnalyzed: false,
  licenseConcluded: "NOASSERTION",
  licenseDeclared: "NOASSERTION",
  copyrightText: "Copyright 2026 Radha AI Products",
} as (typeof packages)[number]);

const sbom = {
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: `Antgrid ${tag}`,
  documentNamespace,
  creationInfo: {
    created: new Date().toISOString(),
    creators: ["Tool: antgrid-generate-spdx-sbom"],
  },
  documentDescribes: ["SPDXRef-Package-Antgrid"],
  extractedLicensingInfo: [
    {
      licenseId: "LicenseRef-Elastic-2.0",
      name: "Elastic License 2.0",
      extractedText: await Bun.file("LICENSES/LicenseRef-Elastic-2.0.txt").text(),
    },
    {
      licenseId: "LicenseRef-Antgrid-Brand",
      name: "Antgrid Brand Assets License",
      extractedText: await Bun.file("LICENSES/LicenseRef-Antgrid-Brand.txt").text(),
    },
    {
      licenseId: "LicenseRef-Third-Party-Trademark",
      name: "Third-party trademark material",
      extractedText: await Bun.file("LICENSES/LicenseRef-Third-Party-Trademark.txt").text(),
    },
  ],
  packages,
  files: spdxFiles,
  relationships: [
    {
      spdxElementId: "SPDXRef-DOCUMENT",
      relationshipType: "DESCRIBES",
      relatedSpdxElement: "SPDXRef-Package-Antgrid",
    },
    ...componentDefinitions.map(([, SPDXID]) => ({
      spdxElementId: "SPDXRef-Package-Antgrid",
      relationshipType: "CONTAINS",
      relatedSpdxElement: SPDXID,
    })),
    ...spdxFiles.map((file) => ({
      spdxElementId: componentFor(file.fileName.slice(2))[1],
      relationshipType: "CONTAINS",
      relatedSpdxElement: file.SPDXID,
    })),
  ],
};

await Bun.write(output, JSON.stringify(sbom, null, 2) + "\n");
