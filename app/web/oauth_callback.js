// Google redirects to oauth_callback.html with ?code=…&state=…; hand them to the app window that opened it.
if (window.opener) {
  window.opener.postMessage({ cryptdriveOAuth: window.location.search }, window.location.origin);
  window.close();
}
