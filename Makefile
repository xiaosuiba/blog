.PHONY: all

all: push release

GIT=git
msg="add post `date`"

.PHONY: push
push:
	${GIT} add -A .
	${GIT} commit -m "$msg"
	${GIT} push origin master

.PHONY: release
release:
	sh ./deploy.sh	
	
debug:
	hugo serve -D