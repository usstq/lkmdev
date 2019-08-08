.RECIPEPREFIX +=

IMG_NAME = lkmdev

.PHONY: default  docker_build docker_save docker_load docker_run chown

default: docker_run

docker_init:
     echo "======== Run once docker-ce has been installed ==========="
     # proxy
     sudo mkdir -p /etc/systemd/system/docker.service.d
     echo Environment=\"HTTP_PROXY=${HTTP_PROXY}\" >   http-proxy.conf
     echo Environment=\"NO_PROXY=${NO_PROXY}\" >> http-proxy.conf
     sudo mv http-proxy.conf /etc/systemd/system/docker.service.d/
     # mirror
     echo {\"registry-mirrors\": [\"https://dockerhub.azk8s.cn\",\"https://reg-mirror.qiniu.com\"]} > daemon.json
     sudo mv daemon.json /etc/docker/
     sudo systemctl daemon-reload
     sudo systemctl restart docker
     # docker w/o sudo
     sudo groupadd docker || echo "docker groups is exist"
     sudo gpasswd -a ${USER} docker
     # test
     sudo docker run hello-world
     @echo "======== Done, next login you can do docker without sudo ========="


docker_build:
     docker build --network=host -t $(IMG_NAME) .

docker_save:
     docker save -o $(IMG_NAME).docker_img $(IMG_NAME)

docker_load:
     docker load -i $(IMG_NAME).docker_img


# we assume pwd is the workspace, so we map it

docker_run:
     #cp ~/.gitconfig ./host_gitconfig
     #xhost +
     docker run --network=host --privileged --rm \
          -v /dev:/dev \
          -v ${HOME}:${HOME} \
          -v `echo ~`/.ssh:/root/.ssh \
          -p 8080:80 \
          --env WORK_DIR=`pwd` \
          --env HOST_USER=${USER} \
          -v /lib/modules/$(shell uname -r)/:/lib/modules/$(shell uname -r)/ \
          -v ~/.Xauthority:/root/.Xauthority \
          -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
          -e DISPLAY=${DISPLAY} \
          --workdir=`pwd` \
          -it $(IMG_NAME) /bin/bash --init-file init-file.sh
     #xhost -
