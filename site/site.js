// Shows the latest version beside the download button. The button works without it.
fetch("https://api.github.com/repos/potatoman03/skylight/releases/latest")
  .then((response) => (response.ok ? response.json() : null))
  .then((release) => {
    const version = release?.tag_name?.replace(/^v/, "");
    if (version) document.getElementById("version").textContent = `Version ${version}, `;
  })
  .catch(() => {});
