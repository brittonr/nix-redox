rec {
  cachePort = 8080;
  hostAddress = "10.0.2.2";
  cacheUrl = "http://${hostAddress}:${toString cachePort}";
}
