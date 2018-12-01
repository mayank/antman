# Antman
Creates docker images and docker-compose using single yml file. Reduces load of dependencies.


## Start Commands
* run `docker.coffee` file to build all the images with latest tags
```
coffee docker.coffee
```

## Setup
* install docker, see installation here. [Docker Installation](https://docs.docker.com/install/)
* coffee script is required to build the docker images
```
apt-get install -y npm
npm install -g coffeescript
```

* install `docker-compose`, for linux use following commands.
```
sudo curl -L https://github.com/docker/compose/releases/download/1.21.2/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
```
```
sudo chmod +x /usr/local/bin/docker-compose
```
See the link for other machines. [Docker Compose Installation](https://docs.docker.com/compose/install/#install-compose)
