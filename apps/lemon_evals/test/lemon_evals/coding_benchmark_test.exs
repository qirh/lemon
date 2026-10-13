defmodule LemonEvals.CodingBenchmarkTest do
  use ExUnit.Case, async: true

  test "omp metrics count assistant messages once rather than replay snapshots" do
    script = ~S'''
    import json, sys
    sys.path.insert(0, sys.argv[1])
    from coding_benchmark import parse_omp
    message = {'role':'assistant','content':[{'type':'text','text':'answer'}],
      'stopReason':'stop','usage':{'input':10,'cacheRead':90,'output':3,'totalTokens':103}}
    events = [{'type':'message_end','message':message},
      {'type':'turn_end','message':message},
      {'type':'tool_execution_end','isError':True},
      {'type':'agent_end','messages':[message]}]
    result = parse_omp('\n'.join(json.dumps(event) for event in events))
    assert result['ok'] and result['answer']=='answer'
    assert result['usage']['totalTokens']==103
    assert result['usage']['cacheReadTokens']==90
    assert result['metrics']=={'turns':1,'tool_errors':1}
    '''

    assert_python(script)
  end

  test "all twelve executable fixtures and external verifiers are syntactically valid" do
    script = ~S'''
    import sys
    sys.path.insert(0, sys.argv[1])
    from coding_benchmark import tasks
    cases=tasks()
    assert len(cases)==12 and len({case['name'] for case in cases})==12
    hard={'inventory_atomic_reservations','order_dependent_policy_cache','vendored_cursor_migration','noisy_retry_log_analysis'}
    assert hard <= {case['name'] for case in cases}
    for case in cases:
      compile(case['verify'], '<external-verifier>', 'exec')
      for name, content in case['files'].items():
        if name.endswith('.py'): compile(content,name,'exec')
    inventory=next(case for case in cases if case['name']=='inventory_atomic_reservations')
    assert len([name for name in inventory['files'] if name.startswith('stockroom/') and name.endswith('.py')]) >= 5
    logs=next(case for case in cases if case['name']=='noisy_retry_log_analysis')
    assert len(logs['files']['logs/worker.jsonl'].splitlines()) > 16000
    '''

    assert_python(script)
  end

  test "profile reports join request and terminal usage without counting ungraded probes" do
    script = ~S'''
    import json, pathlib, subprocess, sys, tempfile
    with tempfile.TemporaryDirectory() as directory:
      root=pathlib.Path(directory)
      benchmark={'results':[{'agent':'lemon','task':'case','run_id':'main'}]}
      (root/'benchmark.json').write_text(json.dumps(benchmark))
      base={'run_id':'main','session_id':'session','request_index':1}
      records=[dict(base,event='payload',estimates={'instructions':8,'tool_schemas':12},repeated_estimates={}),
        dict(base,event='usage',provider_usage={'input_tokens':100,'cache_read_tokens':90,'output_tokens':3,
          'request_fields':{'instructions':{'input_tokens':8,'cached_tokens':8},'tools':{'input_tokens':12,'cached_tokens':12}}}),
        dict(base,event='usage',run_id='probe',provider_usage={'input_tokens':90000})]
      (root/'profile.jsonl').write_text('\n'.join(json.dumps(row) for row in records)+'\n')
      result=subprocess.run([sys.executable,str(pathlib.Path(sys.argv[1])/'profile_report.py'),
        '--input',str(root/'profile.jsonl'),'--benchmark',str(root/'benchmark.json'),'--output',str(root/'report.json')],capture_output=True,text=True)
      assert result.returncode==0,result.stderr
      report=json.loads((root/'report.json').read_text())
      assert report['requests']==1 and report['vendor_usage']['input_tokens']==100
      assert report['vendor_usage']['cached_input_tokens']==90
      assert report['vendor_request_fields']['tools']['input_tokens']==12
      assert report['visible_wire_estimates']['tool_schemas']==12
    '''

    assert_python(script)
  end

  test "profiling crash diagnostics cannot disclose in-memory request bodies" do
    secret = "private-prompt-that-must-not-be-logged"

    status =
      LemonEvals.PayloadProfile.format_status(%{
        message: {:record, :payload, %{instructions: secret}},
        reason: {:encoding_failed, secret},
        log: [secret],
        state: %{port: :profile_port}
      })

    refute inspect(status) =~ secret
    assert status.message == :redacted
  end

  defp assert_python(script) do
    python = System.find_executable("python3") || flunk("python3 is required")
    priv = Path.join(:code.priv_dir(:lemon_evals), "")
    {output, status} = System.cmd(python, ["-c", script, priv], stderr_to_stdout: true)
    assert status == 0, output
  end
end
