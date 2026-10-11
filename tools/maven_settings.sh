# Sourced by the Java build scripts. Maven does not honour HTTP(S)_PROXY, so when such a
# variable is set (corporate proxies, sandboxes) generate a settings.xml under build/ and
# expose it through $MVN. Usage:  . "$BENCH_ROOT/tools/maven_settings.sh"; "${MVN[@]}" package
MVN=(mvn -q -B)
_proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
if [ -n "$_proxy" ]; then
  _hp="${_proxy#*://}"; _hp="${_hp%%/*}"
  _host="${_hp%%:*}"; _port="${_hp##*:}"; [ "$_port" = "$_host" ] && _port=80
  _np="${NO_PROXY:-${no_proxy:-}}"
  mkdir -p build
  cat > build/maven-settings.xml <<XML
<settings>
  <proxies>
    <proxy><id>env-http</id><active>true</active><protocol>http</protocol><host>${_host}</host><port>${_port}</port><nonProxyHosts>${_np//,/|}</nonProxyHosts></proxy>
    <proxy><id>env-https</id><active>true</active><protocol>https</protocol><host>${_host}</host><port>${_port}</port><nonProxyHosts>${_np//,/|}</nonProxyHosts></proxy>
  </proxies>
</settings>
XML
  MVN+=(-s build/maven-settings.xml)
fi
