function handler(event) {
  var request = event.request
  if (request.uri === "${demo_page_path}") {
    return {
      statusCode: 301,
      statusDescription: "Moved Permanently",
      headers: { location: { value: "${demo_page_path}/" } },
    }
  }
  if (request.uri === "${demo_page_path}/") {
    request.uri = "${demo_page_path}/index.html"
  }
  return request
}
