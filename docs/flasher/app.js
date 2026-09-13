const releaseStatus = document.querySelector("#release-status");
const siteRoot = document.documentElement.dataset.siteRoot ?? "";
const language = document.documentElement.lang === "en" ? "en" : "de";
const locale = language === "en" ? "en-GB" : "de-DE";

const copy = {
  de: {
    fallback: "Neueste stabile Firmware",
    published: (date) => `veröffentlicht am ${date}`,
  },
  en: {
    fallback: "Latest stable firmware",
    published: (date) => `published ${date}`,
  },
};

function formatBytes(bytes) {
  return new Intl.NumberFormat(locale, {
    style: "unit",
    unit: "megabyte",
    maximumFractionDigits: 1,
  }).format(bytes / 1_000_000);
}

async function showRelease() {
  try {
    const response = await fetch(`${siteRoot}release.json`, { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`Release-Metadaten: HTTP ${response.status}`);
    }
    const release = await response.json();
    const published = new Intl.DateTimeFormat(locale, {
      day: "2-digit",
      month: language === "en" ? "short" : "2-digit",
      year: "numeric",
    }).format(new Date(release.publishedAt));
    releaseStatus.textContent = `${release.tag} · ${formatBytes(release.firmware.size)} · ${copy[language].published(published)}`;
  } catch (error) {
    console.warn(error);
    releaseStatus.textContent = copy[language].fallback;
  }
}

showRelease();
