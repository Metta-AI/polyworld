import
  std/[os, strutils],
  bassy,
  polyworld/[advisors, llms, timings]

const JevRequest = staticRead("fixtures/jev_request.bas")

echo "Manual paid test: one BASIC request directly to OpenRouter JEV"
block:
  let key = getEnv("OPENROUTER_API_KEY")
  doAssert key.len > 0, "Set OPENROUTER_API_KEY before running this test"
  let advisor = newAdvisor(0, LlmConfig(
    baseUrl: "https://openrouter.ai/api",
    key: key,
    oracleModel: DefaultOracleModel,
    interval: 1,
    timeoutMs: 30_000
  ))
  defer:
    advisor.oracle.client.close()
  var host = initHost()
  advisor.addFunctions(host)
  let program = compile(JevRequest, host)
  var runtime = initRuntime(program, host)
  advisor.bindRuntime(runtime)
  advisor.beginTick(0)
  discard runtime.run()
  let id = runtime.getGlobal("request")
  doAssert id > 0, "BASIC did not submit its JEV request"
  waitForRequests([advisor.requestPoller()])
  let reply = advisor.oracle.client.reply(id)
  echo "HTTP status: ", reply.status
  doAssert reply.status == 200, reply.error & " " & reply.body
  doAssert reply.error.len == 0, reply.error
  advisor.beginTick(1)
  discard runtime.run()
  let
    strategy = runtime.getGlobal("strategy")
    lane = runtime.getGlobal("lane")
    model = runtime.getString(runtime.getGlobalValue("model$"))
  doAssert runtime.getGlobal("answers") == 2, reply.body
  doAssert strategy in 0 .. 4 and lane in 0 .. 2, reply.body
  doAssert model.startsWith("typesafe/jev-"), reply.body
  echo "BASIC strategy index: ", strategy, ", lane index: ", lane
  echo "OpenRouter response: ", reply.body
