const CONFIG_URL = "config.json"
const VIEWER_URL = "/"
const READINESS_URLS = ["/health", "/agent/health", VIEWER_URL]
const POLL_INTERVAL_MILLISECONDS = 10000
const POLL_LIMIT_MILLISECONDS = 10 * 60 * 1000

const startButton = document.getElementById("start")
const statusLine = document.getElementById("status")
const viewerLink = document.getElementById("viewer-link")
const promptField = document.getElementById("prompt")

function formatHour(hour) {
  return `${String(hour).padStart(2, "0")}:00`
}

async function stackIsReady() {
  const responses = await Promise.all(
    READINESS_URLS.map((url) => fetch(url, { cache: "no-store" }).catch(() => null)),
  )
  return responses.every((response) => response !== null && response.ok)
}

function showViewerLink() {
  viewerLink.hidden = false
  startButton.hidden = true
}

async function copyPrompt() {
  try {
    await navigator.clipboard.writeText(promptField.value)
    return "The prompt is on your clipboard."
  } catch {
    return "Copy the prompt above before you go."
  }
}

async function pollUntilReady(clipboardNote) {
  const deadline = Date.now() + POLL_LIMIT_MILLISECONDS
  while (Date.now() < deadline) {
    if (await stackIsReady()) {
      statusLine.textContent = `The demo is up. ${clipboardNote} Sign in, then paste it into the chat panel.`
      showViewerLink()
      window.location.assign(VIEWER_URL)
      return
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MILLISECONDS))
  }
  statusLine.textContent = "The demo did not come up within ten minutes. Try again later."
  startButton.disabled = false
}

async function startDemo(config) {
  startButton.disabled = true
  const clipboardNote = await copyPrompt()
  statusLine.textContent = "Starting the servers. This takes two to three minutes."
  const response = await fetch(config.wakeUrl, { method: "POST" })
  if (!response.ok) {
    statusLine.textContent = `The start request failed with status ${response.status}.`
    startButton.disabled = false
    return
  }
  await pollUntilReady(clipboardNote)
}

async function main() {
  const config = await (await fetch(CONFIG_URL, { cache: "no-store" })).json()
  document.getElementById("hours").textContent =
    `The servers run from ${formatHour(config.morningHour)} to ${formatHour(config.nightlyHour)} ${config.timezone} time. ` +
    `Outside those hours the start button wakes them, and they stop again after ${config.idleMinutes} minutes with no chat.`

  if (await stackIsReady()) {
    statusLine.textContent = "The demo is running. Copy the prompt, open the viewer, sign in, and paste it into the chat panel."
    showViewerLink()
    return
  }
  startButton.addEventListener("click", () => startDemo(config))
}

main()
