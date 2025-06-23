local reconf = config['regexp']

reconf['TO_WRONG_NAME'] = {
  -- match:
  -- To: foo <foo@example.com>;
  re = [[To=/^\s*(\w+)\s+<\1@/i{header}]],
  score = 7.5,
  mime_only = true,
  description = 'The name matches the local-part of the email address',
  group = 'headers'
}
