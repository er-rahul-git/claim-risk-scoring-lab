// Copy to ui/config.js when hosting the UI against AWS. Values come from `terraform output`:
//   PRESIGN_URL = presign_url      (Lambda Function URL)
//   WS_URL      = websocket_url    (API Gateway WebSocket stage)
// Locally you do not need this file: local_stack serves /config.js itself.
window.APP_CONFIG = {
  PRESIGN_URL: "https://xxxxxxxx.lambda-url.ap-south-1.on.aws/",
  WS_URL: "wss://xxxxxxxx.execute-api.ap-south-1.amazonaws.com/nonprod",
  ENV: "nonprod",
};
