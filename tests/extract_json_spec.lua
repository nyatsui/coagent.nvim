-- util.extract_json: the JSON object in a model's reply, tolerant of prose,
-- fences and the usual slips of long replies.
local util = require('coagent.core.util')

describe('util.extract_json', function()
  it('reads a plain object, one in a fence and one after prose with braces', function()
    assert.are.same({ a = 1 }, util.extract_json('{"a": 1}'))
    assert.are.same({ a = 1 }, util.extract_json('Sure:\n```json\n{"a": 1}\n```\nDone.'))
    assert.are.same({ skills = {} }, util.extract_json('Skills for {data} and {x}:\n{"skills": []}', 'skills'))
  end)

  it('repairs raw newlines, tabs, invalid escapes and trailing commas inside the object', function()
    local obj = util.extract_json('{"body": "line 1\nline\t2 \\d+ C:\\path", "list": [1, 2,], }')
    assert.are.equal('line 1\nline\t2 \\d+ C:\\path', obj.body)
    assert.are.same({ 1, 2 }, obj.list)
    -- valid escapes stay as they are
    assert.are.equal('a"b\\n\u{e9}', util.extract_json([[{"s": "a\"b\\n\u00e9"}]]).s)
    -- a comma followed by } inside a string is text, not a trailing comma
    assert.are.equal('x, }', util.extract_json('{"s": "x, }"}').s)
  end)

  it('never mistakes an example object inside the answer for the answer', function()
    -- the outer object is broken beyond repair: an inner example must not be returned with want
    local text = '{"skills": [{"name": "a", "body": "use {"k": 1} here"}]}'
    assert.is_nil((util.extract_json(text, 'skills')))
    -- want picks the object that has the key
    assert.are.same({ skills = { 1 } }, util.extract_json('{"example": true} then {"skills": [1]}', 'skills'))
    assert.are.same({ set = {} }, util.extract_json('{"set": {}}', { 'set', 'question' }))
  end)

  it('says when the object was cut off', function()
    local obj, why = util.extract_json('{"skills": [{"name": "a", "body": "1. one\n2.')
    assert.is_nil(obj)
    assert.are.equal('cut off', why)
    obj, why = util.extract_json('no json here')
    assert.is_nil(obj)
    assert.are.equal('invalid', why)
  end)
end)
