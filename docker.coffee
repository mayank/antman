#!/usr/local/bin/coffee

debug     = require("debug")("docker")

yaml      = require "node-yaml"
fs        = require "fs"
enq       = require "inquirer"
os        = require "os"
dns       = require "dns"
rimraf    = require "rimraf"
request   = require "request"
child     = require "child_process"
cliprog   = require "cli-progress"
ncopy     = require "ncp"
clr       = require "colors/safe"
cli       = require "commander"
ora       = require "ora"

# defines the networks to be declared
network   = 'main'

# registry domain, only support v2 currently
registryDomain = '<put-your-registry-domain-here>'
registry       = 'https://' + registryDomain + '/v2'

# list of all servers needs to be served
servelist = []
mainDir = __dirname + '/services'
tmpDir = __dirname + '/tmp'

# docker-compose file object
compose   =
  version: '3'
  services: {}

# rainbow colors
# used in progress bar
progress  = {}
colors    = [ 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan' ]

gc = ->
  colors[ Math.floor Math.random()*colors.length  ]

getSchema = ( txt ) ->
  "[.white:filled.blue:blank.grey] " + txt + ".white :current.magenta/:total.green "

# line write utils
pr = (a) ->
  console.log (a for c in [1..30]).join ''

# copy file utils
copyFiles = ( source, destination, files = [], ignore = [ "install" ] ) ->
  for file in fs.readdirSync source
    cp = false
    if files and files.length > 0 and file in files then cp = true
    if files.length is 0 then cp = true
    if cp and file not in ignore
      debug 'CopyFiles', 'Source:', source + '/' + file
      debug 'CopyFiles', 'Destination:', destination + '/' + file
      fs.writeFileSync destination + "/" + file, fs.readFileSync source + "/" + file

###
  cli for docker execution
  deprecated, will be removed soon
###
cli
  .version '1.0.0'
  .option '-s, --service [service]', 'Pass service to build'
  .option '-k, --skip', 'Deploy only'
  .option '-c, --cache', 'Force to remove cache'
  .option '-t, --tag [tag]', 'Pass specific tag for the release'
  .option '-d, --debug', 'Prints Everything to Debug'
  .option '-b, --build', 'Force builds images instead of pulling it from registry'
  .option '-n, --network [network]', 'Creates a docker in new network'
  .option '-l, --logs [machine]', 'Get nginx logs of machine'
  .option '-p, --pull', 'Pulls docker images from remote registry'
  .parse process.argv

# reads from docker-compose.yml
# creates Dockerfile for the services
init = (cb) ->

# copy machine files to /config folder in this repo
  copyMachineKeys()

  # read all the services available
  servelist = readAllServices()

  # ask what needs to be deployed
  askForServicesToDeploy()
  .then ->
    askForNetworkSelection()
  .then ->
    deployServices()
  .then ->
    launchInstances()

# launches from docker-compose file
launchInstances = ->
  debug 'launchInstances', 'creating docker-compose'
  file = __dirname + '/docker-compose.yml'
  rimraf.sync file
  stream = fs.createWriteStream file
  stream.write yaml.dump compose

  executor = child.exec 'docker-compose up -d'

  executor.stdout.on 'data', (data) ->
    console.log data

  executor.stderr.on 'data', (data) ->
    console.log data

  new Promise (resolve) ->
    executor.on 'exit', (data) ->
      resolve()

# copy machine files to /config folder in this repo
copyMachineKeys = ->
  debug 'copyMachineKeys', 'copying files to /config/keys'
  copyFiles os.userInfo().homedir + '/.ssh', __dirname + '/config/keys', [ 'id_rsa', 'id_rsa.pub' ]

readAllServices = ->
  services = []
  debug 'readAllServices', 'Dir::', mainDir

  list = fs.readdirSync mainDir
  for dir in list
    if not fs.lstatSync(mainDir).isFile() && fs.existsSync mainDir + '/' + dir + '/setup.yml'
      services.push dir

  debug 'readAllServices', 'Service List::', services
  services

# ask if all needs to be deployed or partial
askForServicesToDeploy = ->
  enq.prompt [
    type: 'checkbox'
    name: 'services'
    message: 'Select Services to Deploy',
    choices: servelist
  ]
  .then (list) ->
    servelist = list.services

# ask for the name of networks which is to be deployed
askForNetworkSelection = ->
  enq.prompt [
    type: 'input'
    name: 'network'
    message: 'Enter the network name (must be unique)'
    default: 'main'
  ]
  .then (list) ->
    network = list.network

# deploying the services
deployServices = ->
  chain = Promise.resolve()

  for service in servelist
    chain = buildMainChain chain, service

  chain

buildMainChain = (chain, service) ->
  chain
    .then ->
      debug 'deployServices', 'Copy Directory to tmp'
      copyDirectoryToTmp service
    .then ->
      debug 'deployServices', 'getJSONFromYAML', service
      getJSONFromYAML service
    .then (json) ->
      debug 'deployServices', 'createDockerfile', service, JSON.stringify json
      createDockerfile service, json
    .then (json) ->
      debug 'deployServices', 'checkImageOnRegistry', service
      checkImageOnRegistry service, json
    .then (json) ->
      debug 'deployServices', 'pullDockerImage', service
      pullDockerImage service, json
    .then (json) ->
      debug 'deployServices', 'pullDockerImage', service
      tagDockerImage service, json
    .catch (json) -> # to be called if issue pulling image from registry
      debug 'deployServices', 'buildDockerImage', service
      buildDockerImage service, json
    .then (json) ->
      debug 'deployServices', 'addToDockerCompose', service
      addToDockerCompose service, json
    .catch (err) ->
      console.log 'deployServices ->', 'Error creating', service
      console.error err

checkImageOnRegistry = (service, json) ->
  new Promise (res, rej) ->
    if cli.build then rej json
    request
      url: registry + '/' + service + '/manifests/latest'
      headers:
        'Accept': 'application/vnd.docker.distribution.manifest.v2+json'
      timeout: 3000
    , (err, resp, body) ->
        debug 'checkImageOnRegistry', err, body
        if err then rej json
        try
          body = JSON.parse body
          size = 0
          size += layer.size for layer in body.layers
          debug 'checkImageOnRegistry', 'Image Found with size', size / 384000, 'MB'
          json[service]['size'] = Math.floor size/384000
          res json
        catch e
          debug 'checkImageOnRegistry, Error', e
          rej json

addToDockerCompose = (service, json) ->
  if compose['services'][service] then delete compose['services'][service]
  compose['services'][service] =
    container_name: network + '-' + service
    image: service + ':latest'
    restart: 'always'

  compose['services'][service]['networks'] = {}
  compose['networks'] = {}
  compose['networks'][network] = null

  debug 'addToDockerCompose', JSON.stringify compose, json

  actions = json[service].service
  if actions.depends_on
    compose['services'][service]['depends_on'] = actions.depends_on

  if actions.aliases
    aliases = []
    for alias in actions.aliases
        if aliases.indexOf(alias) < 0 then aliases.push alias
    aliases.push service
    debug 'addToDockerCompose', 'For Service', service, 'Aliases', aliases

    compose['services'][service]['networks'][network] = {}
    compose['services'][service]['networks'][network]['aliases'] = aliases
  else
    compose['services'][service]['networks'] = [network]

  if actions.ports
    compose['services'][service]['ports'] = actions.ports

  compose['services'][service]['environment'] = {}
  if actions.environment
    compose['services'][service]['environment'] = actions.environment
  compose['services'][service]['environment']['NETWORK'] = network

  if actions.volumes
    if not compose['volumes'] then compose['volumes'] = {}
    for volume in actions.volumes
      vol = volume.split ":"
      compose['volumes'][vol[0]] = null
      compose['services'][service]['volumes'] = actions.volumes

  Promise.resolve()


copyDirectoryToTmp = (service) ->
  debug 'copyDirectoryToTmp', 'recreating tmpDir', tmpDir
  # rimraf.sync tmpDir
  fs.mkdirSync tmpDir

  debug 'copyDirectoryToTmp', 'Source', mainDir + '/' + service
  debug 'copyDirectoryToTmp', 'Destination', tmpDir
  new Promise (resolve) -> ncopy mainDir + '/' + service, tmpDir, (err) ->
    debug 'copyDirectoryToTmp', 'Error', err
    resolve()

getJSONFromYAML = (service) ->
  new Promise (resolve) -> resolve yaml.read mainDir + '/' + service + '/setup.yml'

# creates a temp directory to work on
# puts all the dependencies
# then builds dockerfile
# deletes the directory afterwards
createDockerfile = (service, json) ->
  new Promise (resolve) ->
    cmd = json[service]

    debug 'createDockerFile', 'baseImage', cmd
    writer = fs.createWriteStream tmpDir + "/Dockerfile"
    writer.write "FROM " + cmd.from + "\n"

    buildCommands writer, selector, args, cmd.from for selector, args of cmd.use
    resolve json

# creates the dockerfile using commands in setup.yml
buildCommands = ( writer, selector, args, image ) ->
  install = image.split(":")[0]
  specExists = fs.existsSync "config/" + selector + "/" + install
  installer = "config/" + selector + "/" + if specExists then install else "install"

  if fs.existsSync installer
    debug 'buildCommands', 'copying files', selector
    copyFiles "config/" + selector, tmpDir

    line = if args then for key, val of args
      "ARG " + selector + key + "=" + val + "\n"

    if line
      debug 'buildCommands', 'Arguments', line
      writer.write line.join("") + "\n"

    debug 'buildCommands', 'Installation Commands', installer
    writer.write fs.readFileSync(installer).toString() + "\n"
  else
    commands writer, selector, args

commands = ( writer, selector, args ) ->
  copy writer, args if selector is 'copy'
  exec writer, args if selector is 'cmd'
  entrypoint writer, args if selector is 'run'
  gitmulti writer, args if selector is 'git'

gitmulti = ( writer, args ) ->
  console.log 'Git Multi is Called'

entrypoint = ( writer, args ) ->
  list = "ENTRYPOINT "
  list +=  args.sync.join(" & ") if args.sync
  list += args.async.join(" ; ") if args.async
  list += "\n"
  writer.write list

copy = ( writer, args ) ->
  writer.write "COPY " + str.replace(":"," ") + "\n" for str in args

exec = ( writer, args ) ->
  for cmd in args
    writer.write "WORKDIR " + cmd.in + "\n"
    writer.write "RUN " + command + "\n" for command in cmd.fire

# builds the image for service
# basically docker build command
buildDockerImage = (service, json) ->
  new Promise (resolve, reject) ->
    if cli.skip
      debug 'Skipping', service
      return resolve json

    debug 'buildDockerImage', 'building for', resolve

    cmd = "cd " + tmpDir + "; docker build"
    if cli.cache then cmd += " --no-cache"
    cmd += " --rm -t " + service + ":"
    cmd += "latest"
    cmd += " ."

    debug 'buildDockerImage', 'exec:: ', cmd
    executor = child.exec cmd

    executor.stdout.on 'data', ( data ) ->
      showProgress service, data

    executor.stderr.on 'data', ( data ) ->
      console.log 'Error Occured building Image:', service, data
      showProgress service, data

    executor.on 'exit', ( status ) ->
      debug 'buildDockerImage', 'Exit Status:', status
      if progress and progress.stop then progress.stop()
      rimraf.sync tmpDir
      resolve json

tagDockerImage = (service, json) ->
  new Promise (resolve, reject) ->
    cmd = 'docker tag ' + registryDomain + '/' + service + ':latest ' + service + ':latest'
    executor = child.exec cmd

    executor.on 'exit', ( status ) ->
      debug 'pullDockerImage', 'Exit Status:', status
      resolve json



pullDockerImage = (service, json) ->
  new Promise (resolve, reject) ->
    spinner = ora '[' + service + '] Downloading ' + json[service]['size'] + 'MBs, This will take a while'
    spinner.start()

    cmd = 'docker pull ' + registryDomain + '/' + service + ':latest'
    executor = child.exec cmd

    executor.stdout.on 'data', ( data ) ->
      debug 'pullDockerImage', data

    executor.stderr.on 'data', ( data ) ->
      debug 'pullDockerImage, Error:', data

    executor.on 'exit', ( status ) ->
      spinner.stop()
      debug 'pullDockerImage', 'Exit Status:', status
      if status is 0 then resolve json else reject json


showProgress = (service, data) ->
  debug 'buildDockerImage:$  ', data

  steps = data.match /Step (\d+)\/(\d+) \: (.*)/g
  if steps isnt null

    for step in steps
      mark = step.match /Step (\d+)\/(\d+) \: (.*)/

      if mark[1] is '1'
        progress = new cliprog.Bar
          hideCursor: true
          barsize: 80
        ,
          format: '[' + service + ']' + clr[ gc() ](' {bar}') + ' {percentage}% | {value} parts'
          barCompleteChar: '\u2588'
          barIncompleteChar: '\u2591'

        progress.start mark[2] * 500, 0

      progress.update mark[1] * 500,
        command: mark[3]

    if progress then progress.increment()

# creates dockerfile and builds image
if cli.logs
  cmd = 'docker exec -t dev-' + cli.logs + ' sh -c "tail -f /var/log/nginx/*log"'
  cmd2 = 'docker logs -f --tail=100 dev-' + cli.logs

  executor = child.exec cmd
  executor2 = child.exec cmd2

  executor.stdout.on 'data', ( data ) ->
    console.log data

  executor2.stdout.on 'data', ( data ) ->
    console.log data
else
  init -> console.log '...'
