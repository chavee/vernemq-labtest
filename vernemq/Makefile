# a helper shell script
MAKE_VERSION=1.3.2

define MAKEFUNCTIONCODE
	function hasChanges() {
		# old version, just track uncommited + untracked files
		#		test -n "$$(git status -s .)"
		# expect 1 to be normal so the untracked file .make-funcition will be ignored
		test 0 -ne "$$(git status -s . | sed -e '/.make-function/d' | wc -l)"
	}

	function getRelease() {
		# old : use tag in release.conf
		# awk -F= '/^RELEASE=/{print $$2}' release.conf

		# new use tag from git of the form -> 1.0.1-2-3b10c420
		TAGN=$$(git describe | sed -e "s/-g.*//")
		TV=$$(echo $$TAGN | sed -e "s/-.*//")
		TM=$$(echo $$TAGN | sed -e "s/^[^\-]*//")
		if [ -z "$$TM" ]
		then
			TM="-0"
		fi
		echo $$TV$$TM
	}

	function getBaseTag() {
			sed -n -e "s/^tag=\(.*\)$$(getRelease)\$$/\1/p" release.conf
	}

	function getTag() {
		if [ -z "$$1" ] ; then
			awk -F= '/^tag/{print $$2}' release.conf
		else
			echo "$$(getBaseTag)$$1"
		fi
	}

	function setRelease() {
		if [ -n "$$1" ] ; then
			sed -i.x -e "s/^tag=.*/tag=$$(getTag $$1)/" release.conf
			sed -i.x -e "s/^RELEASE=.*/RELEASE=$$1/g" release.conf
			rm -f release.conf.x
			runPreTagCommand "$$1"
		else
			echo "ERROR: missing release version parameter " >&2
			return 1
		fi
	}

	function runPreTagCommand() {
		if [ -n "$$1" ] ; then
			COMMAND=$$(sed -n -e "s/@@RELEASE@@/$$1/g" -e 's/^pre_tag_command=\(.*\)/\1/p' release.conf)
			if [ -n "$$COMMAND" ] ; then
				if ! OUTPUT=$$(bash -c "$$COMMAND" 2>&1) ; then echo $$OUTPUT >&2 && exit 1 ; fi
			fi
		else
			echo "ERROR: missing release version parameter " >&2
			return 1
		fi
	}

	function tagExists() {
		tag=$${1:-$$(getTag)}
		test -n "$$tag" && test -n "$$(git tag | grep "^$$tag\$$")"
	}

	function differsFromRelease() {
		tag=$$(getTag)
		! tagExists $$tag || test -n "$$(git diff --shortstat -r $$tag .)"
	}

	function getVersion() {
		result=$$(getRelease)

		if hasChanges ; then
			result="$$result-dirty"
		fi
		echo $$result
	}

	function getVersionWithHash() {
		result=$$(getRelease)

		if differsFromRelease; then
            # output only first 7 characters
			# result="$$result-$$(git log -n 1 --format=%h .)"

			# output first 8 characters
			result="$$result-$$(git log -n 1 --format=%H . | head -c 8)"
		fi

		if hasChanges ; then
			result="$$result-dirty"
		fi
		echo $$result
	}

	function getCommitedVersionWithHash() {
		result=$$(getRelease)

		if differsFromRelease; then
            # output only first 7 characters
			# result="$$result-$$(git log -n 1 --format=%h .)"

			# output first 8 characters
			result="$$result-$$(git log -n 1 --format=%H . | head -c 8)"
		fi

		if hasChanges ; then
			result="$$result"
		fi
		echo $$result
	}

	function nextPatchLevel() {
		version=$${1:-$$(getRelease)}
		major_and_minor=$$(echo $$version | cut -d. -f1,2)
		patch=$$(echo $$version | cut -d. -f3)
		version=$$(printf "%s.%d" $$major_and_minor $$(($$patch + 1)))
		echo $$version
	}

	function nextMinorLevel() {
		version=$${1:-$$(getRelease)}
		major=$$(echo $$version | cut -d. -f1);
		minor=$$(echo $$version | cut -d. -f2);
		version=$$(printf "%d.%d.0" $$major $$(($$minor + 1))) ;
		echo $$version
	}

	function nextMajorLevel() {
		version=$${1:-$$(getRelease)}
		major=$$(echo $$version | cut -d. -f1);
		version=$$(printf "%d.0.0" $$(($$major + 1)))
		echo $$version
	}
endef

SHELL=/bin/bash

include release.conf
IMAGE=$(REGISTRY_HOST)/$(GROUPNAME)/$(PROJECTNAME)
VERSION=$(shell . $(RELEASE_SUPPORT) ; getVersion)
VERSIONHASH=$(shell . $(RELEASE_SUPPORT) ; getVersionWithHash)
VERSIONHASHCOMMITED=$(shell . $(RELEASE_SUPPORT) ; getCommitedVersionWithHash)

TAG=$(shell . $(RELEASE_SUPPORT); getTag)
PROJECTPATH?=.
BUILDARG?=

RELEASE_SUPPORT := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))/.make-function
export MAKEFUNCTIONCODE


# If the first argument is "run"...
doit=
ifeq (rmi,$(firstword $(MAKECMDGOALS)))
	doit=true
endif
ifeq (images,$(firstword $(MAKECMDGOALS)))
	doit=true
endif
ifeq (deploy,$(firstword $(MAKECMDGOALS)))
	doit=true
endif
ifeq (deploy-dev,$(firstword $(MAKECMDGOALS)))
	doit=true
endif
ifeq (deploy-debug,$(firstword $(MAKECMDGOALS)))
	doit=true
endif
ifeq (show-deploy,$(firstword $(MAKECMDGOALS)))
	doit=true
endif
ifeq (annotate,$(firstword $(MAKECMDGOALS)))
	doit=true
endif
ifeq (rollback,$(firstword $(MAKECMDGOALS)))
	doit=true
endif
ifdef doit
  # use the rest as arguments for "make xxx"
  #CMD_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  # ...and turn them into do-nothing targets
  #$(eval $(CMD_ARGS):;@:)
  ifdef n
	  DEPLOYARG= -n $(n) --context=$(c)
  else
	  DEPLOYARG= -n nexpieio --context=$(c)
  endif
endif

# ifeq ($(CMD_ARGS),)
# else
# 	EMPTY=
# 	SPACE=$(EMPTY) $(EMPTY)
# 	TDARG = $(subst $(SPACE), --context=,$(CMD_ARGS))
# 	DARG = -n $(TDARG)
# endif


.PHONY: pre-build docker-build post-build build cleanbuild release patch-release minor-release major-release tag check-status check-release showtag  show-tag showtagdeploy show-tagdeploy\
	push do-push post-push post-init update-make rmi images deploy show-deploy annotate rollback

init:
	@echo "$$MAKEFUNCTIONCODE" > ./.make-function

build: init pre-build docker-build post-build

buildx: init pre-build docker-buildx post-build

cleanbuild: init pre-build docker-cleanbuild post-build

pre-build:

post-build:
	@rm .make-function

post-push:
	@rm .make-function

post-init:
	@rm .make-function

docker-buildx:
	docker buildx build --push --platform linux/arm64/v8,linux/amd64 $(BUILDARG) --tag $(IMAGE):$(VERSIONHASH) $(PROJECTPATH)

docker-build:
	docker build --platform=linux/amd64 $(BUILDARG) -t $(IMAGE):$(VERSIONHASH) $(PROJECTPATH)
	@DOCKER_MAJOR=$(shell docker -v | sed -e 's/.*version //' -e 's/,.*//' | cut -d\. -f1) ; \
	DOCKER_MINOR=$(shell docker -v | sed -e 's/.*version //' -e 's/,.*//' | cut -d\. -f2) ; \
	if [ $$DOCKER_MAJOR -eq 1 ] && [ $$DOCKER_MINOR -lt 10 ] ; then \
		echo docker tag -f $(IMAGE):$(VERSIONHASH) $(IMAGE):latest ;\
		docker tag -f $(IMAGE):$(VERSIONHASH) $(IMAGE):latest ;\
		echo docker tag -f $(IMAGE):$(VERSIONHASH) $(IMAGE):$(VERSION) ;\
		docker tag -f $(IMAGE):$(VERSIONHASH) $(IMAGE):$(VERSION) ;\
	else \
		echo docker tag $(IMAGE):$(VERSIONHASH) $(IMAGE):latest ;\
		docker tag $(IMAGE):$(VERSIONHASH) $(IMAGE):latest ; \
		echo docker tag  $(IMAGE):$(VERSIONHASH) $(IMAGE):$(VERSION) ;\
		docker tag  $(IMAGE):$(VERSIONHASH) $(IMAGE):$(VERSION) ;\
	fi

docker-cleanbuild:
	docker build --platform=linux/amd64 --no-cache -t $(IMAGE):$(VERSIONHASH) $(PROJECTPATH)
	@DOCKER_MAJOR=$(shell docker -v | sed -e 's/.*version //' -e 's/,.*//' | cut -d\. -f1) ; \
	DOCKER_MINOR=$(shell docker -v | sed -e 's/.*version //' -e 's/,.*//' | cut -d\. -f2) ; \
	if [ $$DOCKER_MAJOR -eq 1 ] && [ $$DOCKER_MINOR -lt 10 ] ; then \
		echo docker tag -f $(IMAGE):$(VERSIONHASH) $(IMAGE):latest ;\
		docker tag -f $(IMAGE):$(VERSIONHASH) $(IMAGE):latest ;\
		echo docker tag -f $(IMAGE):$(VERSIONHASH) $(IMAGE):$(VERSION) ;\
		docker tag -f $(IMAGE):$(VERSIONHASH) $(IMAGE):$(VERSION) ;\
	else \
		echo docker tag $(IMAGE):$(VERSIONHASH) $(IMAGE):latest ;\
		docker tag $(IMAGE):$(VERSIONHASH) $(IMAGE):latest ; \
		echo docker tag  $(IMAGE):$(VERSIONHASH) $(IMAGE):$(VERSION) ;\
		docker tag  $(IMAGE):$(VERSIONHASH) $(IMAGE):$(VERSION) ;\
	fi

release: check-status check-release build push

push: init do-push post-push

rmi: delete-docker-image

images: list-docker-image

do-push:
	docker push $(IMAGE):$(VERSIONHASH)
	docker push $(IMAGE):$(VERSION)
	docker push $(IMAGE):latest

build-push: build push

show-tag: init release.conf
	@. $(RELEASE_SUPPORT); getVersionWithHash
	@rm .make-function

showtag: init release.conf
	@. $(RELEASE_SUPPORT); getVersionWithHash
	@rm .make-function

show-tagdeploy: init release.conf
	@. $(RELEASE_SUPPORT); getCommitedVersionWithHash
	@rm .make-function

showtagdeploy: init release.conf
	@. $(RELEASE_SUPPORT); getCommitedVersionWithHash
	@rm .make-function

check-status: init
	@. $(RELEASE_SUPPORT) ; ! hasChanges || (echo "ERROR: there are still outstanding changes" >&2) ;
	@rm .make-function

check-release: init release.conf post-init
	@. $(RELEASE_SUPPORT) ; tagExists $(TAG) || (echo "ERROR: version not yet tagged in git. make [minor,major,patch]-release." >&2 && exit 1) ;
	@. $(RELEASE_SUPPORT) ; ! differsFromRelease $(TAG) || (echo "ERROR: current directory differs from tagged $(TAG). make [minor,major,patch]-release." ; exit 1)

update-make: init
	@rm Makefile
	wget https://git.nexpie.com/sample/docker-makefile-sample/raw/master/Makefile
	@rm .make-function

make-version:
	@echo $(MAKE_VERSION)

# awk to cut the column 3, xargs to run command passing arg from pipe
delete-docker-image:
	@docker images | grep $(CMD_ARGS) | awk '{print $$3}' | xargs docker rmi || true

# || true to force exoit code to 0 otherwise if no line matched, make will show some error
list-docker-image:
	@docker images | grep $(CMD_ARGS) || true

env-snippet:
	@jq -r '..|select(type=="string") + "="' config/custom-environment-variables.json > _temp_file_.env
	@keg -s nexpieconfig  _temp_file_.env > /dev/null
	@cat env-snippet-nexpieconfig.yaml
	@rm _temp_file_.env
	@rm nexpieconfig.yaml
	@rm env-snippet-nexpieconfig.yaml


show-deploy:  init release.conf
ifndef c
	@echo Please run make show-deploy c={context}
else
	kubectl rollout history deployment/$(DEPLOYMENT) $(DEPLOYARG)
endif
	@rm .make-function


annotate:  init release.conf
ifndef c
	@echo Please run make show-deploy c={context} a="{annotation text}"
else ifndef a
	@echo Please run make show-deploy c={context} a="{annotation text}"
else
	kubectl annotate deployment/$(DEPLOYMENT) kubernetes.io/change-cause="$(a)" $(DEPLOYARG)
endif
	@rm .make-function


rollback:  init release.conf
ifndef r
	@echo Please run make rollback r={revision} c={context}
else
	kubectl rollout undo deployment/$(DEPLOYMENT) --to-revision=$(r) $(DEPLOYARG)
endif
	@rm .make-function


deploy:  init release.conf
ifndef c
	@echo Deploy failed : Please make deploy with c={context}
else
	@cat k8s/deployment.yaml | sed "s/{{IMAGE_TAG}}/$(VERSIONHASHCOMMITED)/g" | kubectl apply -f - $(DEPLOYARG)
	@rm .make-function
ifdef a
	@kubectl annotate deployment/$(DEPLOYMENT) kubernetes.io/change-cause="$(a)" $(DEPLOYARG)
endif
endif

deploy-dev:  init release.conf
ifndef c
	@echo Deploy failed : Please make deploy with c={context}
else
	@cat k8s/deployment-dev.yaml | sed "s/{{IMAGE_TAG}}/$(VERSIONHASHCOMMITED)/g" | kubectl apply -f - $(DEPLOYARG)
	@rm .make-function
ifdef a
	@kubectl annotate deployment/$(DEPLOYMENT) kubernetes.io/change-cause="$(a)" $(DEPLOYARG)
endif
endif

deploy-debug:  init release.conf
ifndef c
	@echo Deploy failed : Please make deploy with c={context}
else
	@cat k8s/deployment-debug.yaml | sed "s/{{IMAGE_TAG}}/$(VERSIONHASHCOMMITED)/g" | kubectl apply -f - $(DEPLOYARG)
	@rm .make-function
ifdef a
	@kubectl annotate deployment/$(DEPLOYMENT) kubernetes.io/change-cause="$(a)" $(DEPLOYARG)
endif
endif
