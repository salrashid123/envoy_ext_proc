### Envoy External Processing Filter

A really basic implementation of envoy [External Processing Filter](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/ext_proc.proto#envoy-v3-api-msg-extensions-filters-http-ext-proc-v3-externalprocessor).  This capability allows you to define an external gRPC server which can selectively process headers and payload/body of requests (see [External Processing Filter PRD](https://docs.google.com/document/d/1IZqm5IUnG9gc2VqwGaN5C2TZAD9_QbsY9Vvy5vr9Zmw/edit#heading=h.3zlthggr9vvv).  Basically, your own unrestricted filter.

```
          ext_proc 
             ^
             |
client ->  envoy -> upstream
```

>> NOTE, this filter is really early and has a lot of features to implement!

- Source: [ext_proc.cc](https://github.com/envoyproxy/envoy/blob/main/source/extensions/filters/http/ext_proc/ext_proc.cc)

---

All we will demonstrate in this repo is the most basic functionality: manipulate headers and body-content on the request/response.  I know, there are countless other ways to do this with envoy but just as a demonstration of writing the external gRPC server that this functionality uses. If interested, pls read on:

The scenario is like this


A) Manipulate outbound headers and body

```
          ext_proc   (delete specific header from client to upstream; append body content sent to upstream)
             ^
             |
client ->  envoy -> upstream
```

B) Manipulate response headers and body

```
          ext_proc   (delete specific header from upstream to client; append body content sent to client)
             ^
             |
client <-  envoy <- upstream
```


---

Specifically for (A), if a header key= "user" is sent by the client **AND** if the request is a POST, the external processing filter will
 - redact that header
 - append 'foo' to the body and send that to `httpbin.org/post`


If A is triggered, the couple of headers from httpbin are removed and the content type is set to text.  Finally, the response body has the text `qux` appended to it.


If the request type is GET or if the header 'user' is not present no modifications are made

---

First this code was just committed in PR [14385](https://github.com/envoyproxy/envoy/pull/14385) so we will need envoy from the dev branch that was just committed

```bash
docker cp `docker create  envoyproxy/envoy-dev:latest`:/usr/local/bin/envoy .
```

Now start the external gRPC server

```bash
go run grpc_server.go
```

This will start the gRPC server which will receive the requests from envoy.  


I'm not sure if i've implemented the server correctly but the following does redact the `user` header from upstream

```golang

```

As more features are implemented, you can handle new processing request types.  

Now start envoy

```
./envoy -c server.yaml -l debug
```

Note, the external processing filter is by default configured to ONLY ask for the inbound request headers.  What we're going to do in code is first check if the header contains the specific value we're interested in (i.,e header has a 'user' in it), if so, then we will ask for the request body, which will ask for the response headers which inturn will override and ask for the response body

```yaml
          http_filters:
          - name: envoy.filters.http.ext_proc
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3alpha.ExternalProcessor
              failure_mode_allow: false
              async_mode: false              
              request_attributes:
              - user
              response_attributes:
              - server
              processing_mode:
                request_header_mode: "SEND"
                response_header_mode: "SKIP"
                request_body_mode: "NONE"
                response_body_mode: "NONE"
                request_trailer_mode: "SKIP"
                response_trailer_mode: "SKIP"
              grpc_service:
                envoy_grpc:                  
                  cluster_name: ext_proc_cluster
```

Send in some requests


>> note, in each of tests, the upstream is `httpbin.org` which will just echo back the inbound request to the caller and display the headers and body *it got* back as the json response (i.,e the json response below is what httpbin saw)

1) GET Request

In this case, we should not expect any modifications to take place.

```bash
$ curl -v -H "host: http.domain.com"  --resolve  http.domain.com:8080:127.0.0.1  http://http.domain.com:8080/get

> GET /get HTTP/1.1
> Host: http.domain.com
> User-Agent: curl/7.74.0
> Accept: */*


< HTTP/1.1 200 OK
< date: Wed, 31 Mar 2021 16:59:50 GMT
< content-type: application/json
< content-length: 311
< server: envoy
< access-control-allow-origin: *
< access-control-allow-credentials: true
< x-envoy-upstream-service-time: 31

{
  "args": {}, 
  "headers": {
    "Accept": "*/*", 
    "Host": "http.domain.com", 
    "User-Agent": "curl/7.74.0", 
    "X-Amzn-Trace-Id": "Root=1-6064aa86-1e8e99652e2c7ee003a2750f", 
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000"
  }, 
  "origin": "108.51.98.171", 
  "url": "https://http.domain.com/get"
}
```

2) GET Request with user header

Here we're also not expecting changes

```bash
$ curl -v -H "host: http.domain.com"  --resolve  http.domain.com:8080:127.0.0.1  -H "user: sal" http://http.domain.com:8080/get

> GET /get HTTP/1.1
> Host: http.domain.com
> User-Agent: curl/7.74.0
> Accept: */*
> user: sal

< HTTP/1.1 200 OK
< date: Wed, 31 Mar 2021 17:00:37 GMT
< content-type: application/json
< content-length: 331
< server: envoy
< access-control-allow-origin: *
< access-control-allow-credentials: true
< x-envoy-upstream-service-time: 24

{
  "args": {}, 
  "headers": {
    "Accept": "*/*", 
    "Host": "http.domain.com", 
    "User": "sal", 
    "User-Agent": "curl/7.74.0", 
    "X-Amzn-Trace-Id": "Root=1-6064aab5-1c5e1204091c69600d45b6ba", 
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000"
  }, 
  "origin": "108.51.98.171", 
  "url": "https://http.domain.com/get"
}
```

3) POST Request with user header

In this case,we send in a POST but no user header so also no difference

```bash
$ curl -v -H "host: http.domain.com" -H "content-type: text/plain" --resolve  http.domain.com:8080:127.0.0.1  -d 'foo' http://http.domain.com:8080/post

> POST /post HTTP/1.1
> Host: http.domain.com
> User-Agent: curl/7.74.0
> Accept: */*
> content-type: text/plain
> Content-Length: 3

< HTTP/1.1 200 OK
< date: Wed, 31 Mar 2021 17:03:06 GMT
< content-type: application/json
< content-length: 441
< server: envoy
< access-control-allow-origin: *
< access-control-allow-credentials: true
< x-envoy-upstream-service-time: 8

{
  "args": {}, 
  "data": "foo", 
  "files": {}, 
  "form": {}, 
  "headers": {
    "Accept": "*/*", 
    "Content-Length": "3", 
    "Content-Type": "text/plain", 
    "Host": "http.domain.com", 
    "User-Agent": "curl/7.74.0", 
    "X-Amzn-Trace-Id": "Root=1-6064ab4a-6df7e0d437a8ad2637c35fce", 
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000"
  }, 
  "json": null, 
  "origin": "108.51.98.171", 
  "url": "https://http.domain.com/post"
}
```

4) Finally, 

We send a post request and the 'user' header below

What happens is that the external processing filter will

1. In `*pb.ProcessingRequest_RequestHeaders`,  
  - detect and remove `user` header
  - instruct further processing of the request body

2. In `*pb.ProcessingRequest_RequestBody`,
  - append `bar` to the inbound request body
  - update the content-length header (since thats just what we did here by appending)

3. In `*pb.ProcessingRequest_ResponseHeaders`,
  - remove the following headers sent by httpbin:  `"access-control-allow-origin", "access-control-allow-credentials"`
  - update the content-length value by addin in the byte-length contained in the data we're going to later add to the body (i.e, add by #bytes in `qux`) 

4. In `*pb.ProcessingRequest_ResponseBody`
  - Append `qux` to the response body sent by httpbin



```bash
$ curl -v -H "host: http.domain.com" -H "content-type: text/plain" \
  --resolve  http.domain.com:8080:127.0.0.1 \
   -H "user: sal" -d 'foo' http://http.domain.com:8080/post

> POST /post HTTP/1.1
> Host: http.domain.com
> User-Agent: curl/7.74.0
> Accept: */*
> content-type: text/plain
> user: sal
> Content-Length: 3

< HTTP/1.1 200 OK
< date: Wed, 31 Mar 2021 17:05:01 GMT
< server: envoy
< x-envoy-upstream-service-time: 24
< content-type: text/plain
< content-length: 453

{
  "args": {}, 
  "data": "foo baaar ", 
  "files": {}, 
  "form": {}, 
  "headers": {
    "Accept": "*/*", 
    "Content-Length": "10", 
    "Content-Type": "text/plain", 
    "Host": "http.domain.com", 
    "User-Agent": "curl/7.74.0", 
    "X-Amzn-Trace-Id": "Root=1-6064abbd-1a54289105d3cec56cec7c9c", 
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000"
  }, 
  "json": null, 
  "origin": "108.51.98.171", 
  "url": "https://http.domain.com/post"
}

 qux
```

---

Thats it, i'll be adding on more features as they become available to this repo.

--- 

## Other links
Other reference envoy samples

- [Envoy WASM and LUA filters for Certificate Bound Tokens](https://github.com/salrashid123/envoy_cert_bound_token)
- [Envoy mTLS](https://github.com/salrashid123/envoy_mtls)
- [Envoy control plane "hello world"](https://github.com/salrashid123/envoy_control)
- [Envoy for Google Cloud Identity Aware Proxy](https://github.com/salrashid123/envoy_iap)
- [Envoy External Authorization server (envoy.ext_authz) with OPA HelloWorld](https://github.com/salrashid123/envoy_external_authz)
- [Envoy RBAC](https://github.com/salrashid123/envoy_rbac)
- [Envoy Global rate limiting helloworld](https://github.com/salrashid123/envoy_ratelimit)
- [Envoy EDS "hello world"](https://github.com/salrashid123/envoy_discovery)
- [Envoy WASM with external gRPC server](https://github.com/salrashid123/envoy_wasm)
- [Redis AUTH and mTLS with Envoy](https://github.com/salrashid123/envoy_redis)

- [gRPC per method observability with envoy, Istio, OpenCensus and GKE](https://github.com/salrashid123/grpc_stats_envoy_istio#envoy)
- [gRPC XDS](https://github.com/salrashid123/grpc_xds)
- [gRPC ALTS](https://github.com/salrashid123/grpc_alts)

