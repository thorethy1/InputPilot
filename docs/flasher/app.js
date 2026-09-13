const releaseStatus = document.querySelector("#release-status");

function formatBytes(bytes) {
  return new Intl.NumberFormat("de-DE", {
    style: "unit",
    unit: "megabyte",
    maximumFractionDigits: 1,
  }).format(bytes / 1_000_000);
}

async function showRelease() {
  try {
    const response = await fetch("release.json", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`Release-Metadaten: HTTP ${response.status}`);
    }
    const release = await response.json();
    const published = new Intl.DateTimeFormat("de-DE", {
      day: "2-digit",
      month: "2-digit",
      year: "numeric",
    }).format(new Date(release.publishedAt));
    releaseStatus.textContent = `${release.tag} · ${formatBytes(release.firmware.size)} · veröffentlicht am ${published}`;
  } catch (error) {
    console.warn(error);
    releaseStatus.textContent = "Neueste stabile Firmware";
  }
}

showRelease();
