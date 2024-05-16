local reconf = config['regexp']

reconf['TO_WRONG_NAME'] = {
  re = [[To=/(\w+) <\1@/]],
  score = 12.0,
  mime_only = true,
  description = 'The name matches the local-part of the email address',
  group = 'headers'
}
