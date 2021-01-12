### Envoy External Processing Filter

A really basic implementation of envoy [External Processing Filter](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3alpha/ext_proc.proto#external-processing-filter).  This capability allows you to define an external gRPC server which can selectively process headers and payload/body of requests (see [External Processing Filter PRD](https://docs.google.com/document/d/1IZqm5IUnG9gc2VqwGaN5C2TZAD9_QbsY9Vvy5vr9Zmw/edit#heading=h.3zlthggr9vvv).  Basically, your own unrestricted filter.

```
          ext_proc   (redact specific header from client to upstream)
             ^
             |
client ->  envoy -> upstream
```

>> NOTE, this filter is really early and has a lot of features to implement!

---

All we will demonstrate in this repo is the most basic functionality:  simply remove a specific heder sent by the client.  I know, there are countless other ways to do this with envoy but just as a demonstration of writing the external gRPC server that this functionality uses. If interested, pls read on:


First this code was just commited in PR [14385](https://github.com/envoyproxy/envoy/pull/14385) so we will need envoy from the dev branch that was just committed

```bash
docker cp `docker create envoyproxy/envoy-dev:5c801b25cae04f06bf48248c90e87d623d7a6283`:/usr/local/bin/envoy .
  ./envoy  version: 483dd3007f15e47deed0a29d945ff776abb37815/1.17.0-dev/Clean/RELEASE/BoringSSL
```

Now start the external gRPC server

```bash
go run grpc_server.go
```

This will start the gRPC server which will receive the requests from envoy.  


I'm not sure if i've impelemnted the server correctly but the following does redact the `user` header from upstream

```golang
func (s *server) Process(srv pb.ExternalProcessor_ProcessServer) error {

	log.Println("Got stream:  -->  ")
	ctx := srv.Context()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		req, err := srv.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			log.Printf("receive error %v", err)
			continue
		}

		var resp *pb.ProcessingResponse
		switch v := req.Request.(type) {
		case *pb.ProcessingRequest_RequestHeaders:
			log.Printf("pb.ProcessingRequest_RequestHeaders %v \n", v)
			r := req.Request
			h := r.(*pb.ProcessingRequest_RequestHeaders)
			for _, n := range h.RequestHeaders.Headers.Headers {
				log.Printf("Header %s %s", n.Key, n.Value)
				if n.Key == "user" {					
					log.Printf(">>>> Processing User Header")
					rhq := &pb.HeadersResponse{
						Response: &pb.CommonResponse{
							HeaderMutation: &pb.HeaderMutation{
								RemoveHeaders: []string{"user"},
							},
						},
					}

					resp = &pb.ProcessingResponse{
						Response: &pb.ProcessingResponse_RequestHeaders{
							RequestHeaders: rhq,
						},
						// ModeOverride: &v3alpha.ProcessingMode{
						// 	RequestBodyMode: v3alpha.ProcessingMode_BUFFERED,
						// },
					}
					if err := srv.Send(resp); err != nil {
						log.Printf("send error %v", err)
					}
					return nil
				}
			}

		case *pb.ProcessingRequest_RequestBody:
			log.Printf("pb.ProcessingRequest_RequestBody %v \n", v)
			r := req.Request
			b := r.(*pb.ProcessingRequest_RequestBody)
			log.Printf("RequestBody: %v", b)
			break
		case *pb.ProcessingRequest_ResponseHeaders:
			log.Printf("pb.ProcessingRequest_ResponseHeaders %v \n", v)
			break
		case *pb.ProcessingRequest_ResponseBody:
			log.Printf("pb.ProcessingRequest_ResponseBody %v \n", v)
			break
		default:
			log.Printf("Unknown Request type %v\n", v)
		}
		if err := srv.Send(resp); err != nil {
			log.Printf("send error %v", err)
		}

	}
}
```

As more features are implemented, you can handle new processing request types.  

Now start envoy

```
./envoy -c server.yaml -l debug
```


Send in a user request (not the header value)

```bash
$ curl -v -H "host: http.domain.com"  --resolve  http.domain.com:8080:127.0.0.1  -H "user: sal" http://http.domain.com:8080/get
```

Note that we send in `user: sal` as the header.

The response JSON you see there is the header **received** by the upstream (httpbin) simply echo'd back to the client.  Note that httpbin did not get that header.

 In other words, our filter redacted this header value

```bash
> GET /get HTTP/1.1
> Host: http.domain.com
> User-Agent: curl/7.72.0
> Accept: */*
> user: sal
> 

< HTTP/1.1 200 OK
< date: Tue, 12 Jan 2021 00:24:19 GMT
< content-type: application/json
< content-length: 338
< server: envoy
< access-control-allow-origin: *
< access-control-allow-credentials: true
< x-envoy-upstream-service-time: 62

{
  "args": {}, 
  "headers": {
    "Accept": "*/*", 
    "Content-Length": "0", 
    "Host": "http.domain.com", 
    "User-Agent": "curl/7.72.0", 
    "X-Amzn-Trace-Id": "Root=1-5ffcec33-584741a32a36fdfa1efc38cf", 
    "X-Envoy-Expected-Rq-Timeout-Ms": "15000"
  }, 
  "origin": "69.250.44.79", 
  "url": "https://http.domain.com/get"
}

```


Here are the envoy logs that show the ext grpc request

```log
[2021-01-11 19:24:19.911][406520][debug][conn_handler] [source/server/connection_handler_impl.cc:501] [C3] new connection
[2021-01-11 19:24:19.911][406520][debug][http] [source/common/http/conn_manager_impl.cc:254] [C3] new stream
[2021-01-11 19:24:19.911][406520][debug][http] [source/common/http/conn_manager_impl.cc:886] [C3][S5237988511417372870] request headers complete (end_stream=true):
':authority', 'http.domain.com'
':path', '/get'
':method', 'GET'
'user-agent', 'curl/7.72.0'
'accept', '*/*'
'user', 'sal'

[2021-01-11 19:24:19.911][406520][debug][http] [source/common/http/filter_manager.cc:755] [C3][S5237988511417372870] request end stream
[2021-01-11 19:24:19.912][406520][debug][router] [source/common/router/router.cc:425] [C0][S6098826058427749220] cluster 'ext_proc_cluster' match for URL '/envoy.service.ext_proc.v3alpha.ExternalProcessor/Process'
[2021-01-11 19:24:19.912][406520][debug][router] [source/common/router/router.cc:582] [C0][S6098826058427749220] router decoding headers:
':method', 'POST'
':path', '/envoy.service.ext_proc.v3alpha.ExternalProcessor/Process'
':authority', 'ext_proc_cluster'
':scheme', 'http'
'te', 'trailers'
'grpc-timeout', '200m'
'content-type', 'application/grpc'
'x-envoy-internal', 'true'
'x-forwarded-for', '192.168.1.22'
'x-envoy-expected-rq-timeout-ms', '200'

[2021-01-11 19:24:19.912][406520][debug][pool] [source/common/http/conn_pool_base.cc:79] queueing stream due to no available connections
[2021-01-11 19:24:19.912][406520][debug][pool] [source/common/conn_pool/conn_pool_base.cc:106] creating a new connection
[2021-01-11 19:24:19.912][406520][debug][client] [source/common/http/codec_client.cc:41] [C4] connecting
[2021-01-11 19:24:19.912][406520][debug][connection] [source/common/network/connection_impl.cc:860] [C4] connecting to 127.0.0.1:18080
[2021-01-11 19:24:19.912][406520][debug][connection] [source/common/network/connection_impl.cc:876] [C4] connection in progress
[2021-01-11 19:24:19.912][406520][debug][http2] [source/common/http/http2/codec_impl.cc:1184] [C4] updating connection-level initial window size to 268435456
[2021-01-11 19:24:19.912][406520][debug][connection] [source/common/network/connection_impl.cc:666] [C4] connected
[2021-01-11 19:24:19.912][406520][debug][client] [source/common/http/codec_client.cc:80] [C4] connected
[2021-01-11 19:24:19.912][406520][debug][pool] [source/common/conn_pool/conn_pool_base.cc:225] [C4] attaching to next stream
[2021-01-11 19:24:19.912][406520][debug][pool] [source/common/conn_pool/conn_pool_base.cc:130] [C4] creating stream
[2021-01-11 19:24:19.912][406520][debug][router] [source/common/router/upstream_request.cc:354] [C0][S6098826058427749220] pool ready
[2021-01-11 19:24:19.915][406520][debug][router] [source/common/router/router.cc:1174] [C0][S6098826058427749220] upstream headers complete: end_stream=false
[2021-01-11 19:24:19.915][406520][debug][http] [source/common/http/async_client_impl.cc:101] async http request response headers (end_stream=false):
':status', '200'
'content-type', 'application/grpc'

[2021-01-11 19:24:19.915][406520][debug][filter] [source/extensions/filters/http/ext_proc/ext_proc.cc:54] Received gRPC message. State = 1
[2021-01-11 19:24:19.915][406520][debug][filter] [source/extensions/filters/http/ext_proc/ext_proc.cc:59] applying request_headers response
[2021-01-11 19:24:19.915][406520][debug][router] [source/common/router/router.cc:425] [C3][S5237988511417372870] cluster 'service_httpbin' match for URL '/get'
[2021-01-11 19:24:19.915][406520][debug][router] [source/common/router/router.cc:582] [C3][S5237988511417372870] router decoding headers:
':authority', 'http.domain.com'
':path', '/get'
':method', 'GET'
':scheme', 'https'
'user-agent', 'curl/7.72.0'
'accept', '*/*'
'x-forwarded-proto', 'http'
'x-request-id', '43f9f971-b43a-4856-bf23-2eb92dc976c3'
'x-envoy-expected-rq-timeout-ms', '15000'

[2021-01-11 19:24:19.915][406520][debug][pool] [source/common/http/conn_pool_base.cc:79] queueing stream due to no available connections
[2021-01-11 19:24:19.915][406520][debug][pool] [source/common/conn_pool/conn_pool_base.cc:106] creating a new connection
[2021-01-11 19:24:19.915][406520][debug][client] [source/common/http/codec_client.cc:41] [C5] connecting
[2021-01-11 19:24:19.915][406520][debug][connection] [source/common/network/connection_impl.cc:860] [C5] connecting to 3.211.1.78:443
[2021-01-11 19:24:19.915][406520][debug][connection] [source/common/network/connection_impl.cc:876] [C5] connection in progress
[2021-01-11 19:24:19.915][406520][debug][client] [source/common/http/codec_client.cc:112] [C4] response complete
[2021-01-11 19:24:19.915][406520][debug][pool] [source/common/conn_pool/conn_pool_base.cc:159] [C4] destroying stream: 0 remaining
[2021-01-11 19:24:19.915][406520][debug][router] [source/common/router/upstream_request.cc:296] [C0][S6098826058427749220] resetting pool request
[2021-01-11 19:24:19.915][406520][debug][http] [source/common/http/async_client_impl.cc:128] async http request response trailers:
'grpc-status', '0'
'grpc-message', ''

[2021-01-11 19:24:19.915][406520][debug][filter] [source/extensions/filters/http/ext_proc/ext_proc.cc:114] Received gRPC stream close
[2021-01-11 19:24:19.915][406520][debug][http2] [source/common/http/http2/codec_impl.cc:964] [C4] stream closed: 0
[2021-01-11 19:24:19.915][406520][debug][http2] [source/common/http/http2/codec_impl.cc:873] [C4] sent reset code=0
[2021-01-11 19:24:19.928][406520][debug][connection] [source/common/network/connection_impl.cc:666] [C5] connected
[2021-01-11 19:24:19.961][406520][error][envoy_bug] [source/extensions/transport_sockets/tls/context_impl.cc:643] envoy bug failure: value_stat_name != fallback. Details: Unexpected ssl.sigalgs value: rsa_pkcs1_sha512
[2021-01-11 19:24:19.961][406520][debug][client] [source/common/http/codec_client.cc:80] [C5] connected
[2021-01-11 19:24:19.961][406520][debug][pool] [source/common/conn_pool/conn_pool_base.cc:225] [C5] attaching to next stream
[2021-01-11 19:24:19.961][406520][debug][pool] [source/common/conn_pool/conn_pool_base.cc:130] [C5] creating stream
[2021-01-11 19:24:19.961][406520][debug][router] [source/common/router/upstream_request.cc:354] [C3][S5237988511417372870] pool ready
[2021-01-11 19:24:19.978][406520][debug][router] [source/common/router/router.cc:1174] [C3][S5237988511417372870] upstream headers complete: end_stream=false
[2021-01-11 19:24:19.979][406520][debug][http] [source/common/http/conn_manager_impl.cc:1484] [C3][S5237988511417372870] encoding headers via codec (end_stream=false):
':status', '200'
'date', 'Tue, 12 Jan 2021 00:24:19 GMT'
'content-type', 'application/json'
'content-length', '338'
'server', 'envoy'
'access-control-allow-origin', '*'
'access-control-allow-credentials', 'true'
'x-envoy-upstream-service-time', '62'
```

and the grpc server logs

```log
$ go run grpc_server.go 
2021/01/11 19:23:41 Starting gRPC server on port :18080
2021/01/11 19:23:43 Handling grpc Check request + service:"envoy.service.ext_proc.v3alpha.ExternalProcessor"
2021/01/11 19:23:49 Handling grpc Check request + service:"envoy.service.ext_proc.v3alpha.ExternalProcessor"
2021/01/11 19:23:54 Handling grpc Check request + service:"envoy.service.ext_proc.v3alpha.ExternalProcessor"
2021/01/11 19:23:59 Handling grpc Check request + service:"envoy.service.ext_proc.v3alpha.ExternalProcessor"
2021/01/11 19:24:05 Handling grpc Check request + service:"envoy.service.ext_proc.v3alpha.ExternalProcessor"
2021/01/11 19:24:10 Handling grpc Check request + service:"envoy.service.ext_proc.v3alpha.ExternalProcessor"
2021/01/11 19:24:16 Handling grpc Check request + service:"envoy.service.ext_proc.v3alpha.ExternalProcessor"
2021/01/11 19:24:19 Got stream:  -->  
2021/01/11 19:24:19 pb.ProcessingRequest_RequestHeaders &{headers:{headers:{key:":authority"  value:"http.domain.com"}  headers:{key:":path"  value:"/get"}  headers:{key:":method"  value:"GET"}  headers:{key:"user-agent"  value:"curl/7.72.0"}  headers:{key:"accept"  value:"*/*"}  headers:{key:"user"  value:"sal"}  headers:{key:"x-forwarded-proto"  value:"http"}  headers:{key:"x-request-id"  value:"43f9f971-b43a-4856-bf23-2eb92dc976c3"}}  end_of_stream:true} 
2021/01/11 19:24:19 Header :authority http.domain.com
2021/01/11 19:24:19 Header :path /get
2021/01/11 19:24:19 Header :method GET
2021/01/11 19:24:19 Header user-agent curl/7.72.0
2021/01/11 19:24:19 Header accept */*
2021/01/11 19:24:19 Header user sal
2021/01/11 19:24:19 >>>> Processing User Header
2021/01/11 19:24:21 Handling grpc Check request + service:"envoy.service.ext_proc.v3alpha.ExternalProcessor"
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

