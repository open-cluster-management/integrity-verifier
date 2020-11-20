# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# LOAD ENVIRNOMENT SETTINGS (must be done at first)
###########################
ifeq ($(IE_REPO_ROOT),)
$(error IE_REPO_ROOT is not set)
endif

include  .env
export $(shell sed 's/=.*//' .env)

ifeq ($(ENV_CONFIG),)
$(error ENV_CONFIG is not set)
endif

include  $(ENV_CONFIG)
export $(shell sed 's/=.*//' $(ENV_CONFIG))

include $(VERIFIER_OP_DIR)Makefile


# CICD BUILD HARNESS
####################
ifeq ($(UPSTREAM_ENV),true)
  USE_VENDORIZED_BUILD_HARNESS = false
else
  USE_VENDORIZED_BUILD_HARNESS ?=
endif


ifndef USE_VENDORIZED_BUILD_HARNESS
-include $(shell curl -s -H 'Authorization: token ${GITHUB_TOKEN}' -H 'Accept: application/vnd.github.v4.raw' -L https://api.github.com/repos/open-cluster-management/build-harness-extensions/contents/templates/Makefile.build-harness-bootstrap -o .build-harness-bootstrap; echo .build-harness-bootstrap)
else
#-include vbh/.build-harness-bootstrap
-include $(shell curl -sSL -o .build-harness "https://git.io/build-harness"; echo .build-harness)
endif
####################

.PHONY: default
default::
	@echo "Build Harness Bootstrapped"

# Docker build flags
DOCKER_BUILD_FLAGS := --build-arg VCS_REF=$(GIT_COMMIT) $(DOCKER_BUILD_FLAGS)

# This repo is build in Travis-ci by default;
# Override this variable in local env.
TRAVIS_BUILD ?= 1

# Image URL to use all building/pushing image targets;
# Use your own docker registry and image name for dev/test by overridding the IMG and REGISTRY environment variable.
#IMG ?= $(shell cat COMPONENT_NAME 2> /dev/null)
#VERSION ?= $(shell cat COMPONENT_VERSION 2> /dev/null)

# Github host to use for checking the source tree;
# Override this variable ue with your own value if you're working on forked repo.
GIT_HOST ?= github.com/IBM

PWD := $(shell pwd)
BASE_DIR := $(shell basename $(PWD))

# Keep an existing GOPATH, make a private one if it is undefined
GOPATH_DEFAULT := $(PWD)/.go
export GOPATH ?= $(GOPATH_DEFAULT)
GOBIN_DEFAULT := $(GOPATH)/bin
export GOBIN ?= $(GOBIN_DEFAULT)
TESTARGS_DEFAULT := "-v"
export TESTARGS ?= $(TESTARGS_DEFAULT)
DEST ?= $(GOPATH)/src/$(GIT_HOST)/$(BASE_DIR)


LOCAL_OS := $(shell uname)
ifeq ($(LOCAL_OS),Linux)
    TARGET_OS ?= linux
    XARGS_FLAGS="-r"
else ifeq ($(LOCAL_OS),Darwin)
    TARGET_OS ?= darwin
    XARGS_FLAGS=
else
    $(error "This system's OS $(LOCAL_OS) isn't recognized/supported")
endif


.PHONY: config int fmt lint test coverage build build-images


config:
	@[ "${ENV_CONFIG}" ] && echo "Env config is all good" || ( echo "ENV_CONFIG is not set"; exit 1 )


############################################################
# format section
############################################################

# All available format: format-go format-protos format-python
# Default value will run all formats, override these make target with your requirements:
#    eg: fmt: format-go format-protos
fmt: format-go


format-go:
	@set -e; \
	GO_FMT=$$(git ls-files *.go | grep -v 'vendor/' | grep -v 'third_party/' | xargs gofmt -d); \
	if [ -n "$${GO_FMT}" ] ; then \
		echo "Please run go fmt"; \
		echo "$$GO_FMT"; \
		exit 1; \
	fi

############################################################
# check section
############################################################

check: lint

# All available linters: lint-dockerfiles lint-scripts lint-yaml lint-copyright-banner lint-go lint-python lint-helm lint-markdown lint-sass lint-typescript lint-protos
# Default value will run all linters, override these make target with your requirements:
#    eg: lint: lint-go lint-yaml
lint: lint-init  lint-verify lint-op-init lint-op-verify

lint-init:
	cd $(VERIFIER_DIR) && golangci-lint run --timeout 5m -D errcheck,unused,gosimple,deadcode,staticcheck,structcheck,ineffassign,varcheck > lint_results.txt

lint-verify:
	$(eval FAILURES=$(shell cat $(VERIFIER_DIR)lint_results.txt | grep "FAIL:"))
	cat $(VERIFIER_DIR)lint_results.txt
	@$(if $(strip $(FAILURES)), echo "One or more linters failed. Failures: $(FAILURES)"; exit 1, echo "All linters are passed successfully."; exit 0)

lint-op-init:
	cd $(VERIFIER_OP_DIR) && golangci-lint run --timeout 5m -D errcheck,unused,gosimple,deadcode,staticcheck,structcheck,ineffassign,varcheck,govet > lint_results.txt

lint-op-verify:
	$(eval FAILURES=$(shell cat $(VERIFIER_OP_DIR)lint_results.txt | grep "FAIL:"))
	cat $(VERIFIER_OP_DIR)lint_results.txt
	@$(if $(strip $(FAILURES)), echo "One or more linters failed. Failures: $(FAILURES)"; exit 1, echo "All linters are passed successfully."; exit 0)


############################################################
# images section
############################################################

build-images:
	$(IE_REPO_ROOT)/build/build_images.sh

.ONESHELL:
docker-login:
		if [ -z "${DOCKER_REGISTRY}" ]; then
			echo "DOCKER_REGISTRY is empty."
			exit 1;
		fi
		if [ -z "${DOCKER_USER}" ]; then
			echo "DOCKER_USER is empty."
			exit 1;
		fi
		if [ -z "${DOCKER_PASS}" ]; then
			echo "DOCKER_PASS is empty."
			exit 1;
		fi
		docker login ${DOCKER_REGISTRY} -u ${DOCKER_USER} -p ${DOCKER_PASS}

.ONESHELL:
push-images: docker-login
		${IE_REPO_ROOT}/build/push_images.sh

.ONESHELL:
pull-images: docker-login
		${IE_REPO_ROOT}/build/pull_images.sh

############################################################
# bundle section
############################################################
.ONESHELL:
build-bundle:
		if [ ${UPSTREAM_ENV} = true ]; then
			if [ -z "${QUAY_REGISTRY}" ]; then
				echo "QUAY_REGISTRY is empty."
				exit 1;
			fi
			if [ -z "${QUAY_USER}" ]; then
				echo "QUAY_USER is empty."
				exit 1;
			fi
			if [ -z "${QUAY_PASS}" ]; then
				echo "QUAY_PASS is empty."
				exit 1;
			fi
			docker login ${QUAY_REGISTRY} -u ${QUAY_USER} -p ${QUAY_PASS}
			$(IE_REPO_ROOT)/build/build_bundle.sh
		else
			$(IE_REPO_ROOT)/build/build_bundle_ocm.sh
		fi

############################################################
# clean section
############################################################
clean::

############################################################
# check copyright section
############################################################
copyright-check:
	 - $(IE_REPO_ROOT)/build/copyright-check.sh $(TRAVIS_BRANCH)

############################################################
# unit test section
############################################################

test-unit: test-init test-verify

test-init:
	cd $(VERIFIER_DIR) &&  go test -v  $(shell cd $(VERIFIER_DIR) && go list ./... | grep -v /vendor/ | grep -v /pkg/util/kubeutil | grep -v /pkg/util/sign/pgp) > results.txt
test-verify:
	$(eval FAILURES=$(shell cat $(VERIFIER_DIR)results.txt | grep "FAIL:"))
	cat $(VERIFIER_DIR)results.txt
	@$(if $(strip $(FAILURES)), echo "One or more unit tests failed. Failures: $(FAILURES)"; exit 1, echo "All unit tests passed successfully."; exit 0)


############################################################
# e2e test section
############################################################
.PHONY: kind-bootstrap-cluster
kind-bootstrap-cluster: kind-create-cluster install-crds install-resources

.PHONY: kind-bootstrap-cluster-dev
kind-bootstrap-cluster-dev: kind-create-cluster install-crds install-resources

#check-env:
#ifndef DOCKER_USER
#	$(error DOCKER_USER is undefined)
#endif
#ifndef DOCKER_PASS
#	$(error DOCKER_PASS is undefined)
#endif

#kind-deploy-controller: check-env
#	@echo installing config policy controller

TEST_SIGNERS=TestSigner
TEST_SIGNER_SUBJECT_EMAIL=signer@enterprise.com
TEST_SECRET=keyring_secret

test-e2e: kind-create-cluster setup-image install-crds setup-iv-env install-resources setup-cr setup-test-resources setup-test-env e2e-test delete-test-env delete-keyring-secret delete-resources kind-delete-cluster

test-e2e-no-init: push-images-to-local setup-iv-env install-crds install-resources setup-cr setup-test-env setup-test-resources e2e-test

kind-create-cluster:
	@echo "creating cluster"
	# kind create cluster --name test-managed
	bash $(VERIFIER_OP_DIR)test/create-kind-cluster.sh
	kind get kubeconfig --name test-managed > $(VERIFIER_OP_DIR)kubeconfig_managed

kind-delete-cluster:
	@echo deleting cluster
	kind delete cluster --name test-managed

install-crds:
	@echo installing crds
	kustomize build $(VERIFIER_OP_DIR)config/crd | kubectl apply -f -

delete-crds:
	@echo deleting crds
	kustomize build $(VERIFIER_OP_DIR)config/crd | kubectl delete -f -

setup-iv-env:
	@echo
	@echo creating namespaces
	kubectl create ns $(IV_OP_NS)
	@echo creating keyring-secret
	kubectl create -f $(VERIFIER_OP_DIR)test/deploy/keyring_secret.yaml -n $(IV_OP_NS)

delete-keyring-secret:
	@echo
	@echo deleting keyring-secret
	kubectl delete -f $(VERIFIER_OP_DIR)test/deploy/keyring_secret.yaml -n $(IV_OP_NS)

install-resources:
	@echo
	@echo setting image
	cd $(VERIFIER_OP_DIR)config/manager && kustomize edit set image controller=localhost:5000/$(IV_OPERATOR):$(VERSION)
	@echo installing operator
	kustomize build $(VERIFIER_OP_DIR)config/default | kubectl apply --validate=false -f -

delete-resources:
	@echo
	@echo deleting operator
	kustomize build $(VERIFIER_OP_DIR)config/default | kubectl delete -f -

setup-image: pull-images push-images-to-local

push-images-to-local:
	@echo push image into local registry
	docker tag $(IV_SERVER_IMAGE_NAME_AND_VERSION) localhost:5000/$(IV_IMAGE):$(VERSION)
	docker tag $(IV_LOGGING_IMAGE_NAME_AND_VERSION) localhost:5000/$(IV_LOGGING):$(VERSION)
	docker tag $(IV_OPERATOR_IMAGE_NAME_AND_VERSION) localhost:5000/$(IV_OPERATOR):$(VERSION)
	docker push localhost:5000/$(IV_IMAGE):$(VERSION)
	docker push localhost:5000/$(IV_LOGGING):$(VERSION)
	docker push localhost:5000/$(IV_OPERATOR):$(VERSION)

setup-cr:
	@echo
	@echo prepare cr
	@echo copy cr into test dir
	cp $(VERIFIER_OP_DIR)config/samples/apis_v1alpha1_integrityenforcer_local.yaml $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml
	@echo insert image
	yq write -i $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml spec.logger.image localhost:5000/$(IV_LOGGING):$(VERSION)
	yq write -i $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml spec.server.image localhost:5000/$(IV_IMAGE):$(VERSION)
	@echo setup signer policy
	yq write -i $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml spec.signPolicy.policies[2].namespaces[0] $(TEST_NS)
	yq write -i $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml spec.signPolicy.policies[2].signers[0] $(TEST_SIGNERS)
	yq write -i $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml spec.signPolicy.signers[1].name $(TEST_SIGNERS)
	yq write -i $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml spec.signPolicy.signers[1].secret $(TEST_SECRET)
	yq write -i $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml spec.signPolicy.signers[1].subjects[0].email $(TEST_SIGNER_SUBJECT_EMAIL)


setup-test-env:
	@echo
	@echo creating test namespace
	kubectl create ns $(TEST_NS)

delete-test-env:
	@echo
	@echo deleting test namespace
	kubectl delete ns $(TEST_NS)

setup-test-resources:
	@echo
	@echo prepare cr for updating test
	cp $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer.yaml $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer_update.yaml
	yq write -i $(VERIFIER_OP_DIR)test/deploy/apis_v1alpha1_integrityenforcer_update.yaml spec.signPolicy.signers[1].subjects[1].email test@enterprise.com

e2e-test:
	@echo
	@echo run test
	cd $(VERIFIER_OP_DIR) && go test -v ./test/e2e > $(VERIFIER_OP_DIR)e2e_results.txt
	$(eval FAILURES=$(shell cat $(VERIFIER_OP_DIR)e2e_results.txt | grep "FAIL:"))
	cat $(VERIFIER_OP_DIR)e2e_results.txt
	echo Fail:$(strip $(FAILURES))
	@$(if $(strip $(FAILURES)), echo "One or more e2e tests failed. Failures: $(FAILURES)"; exit 1, echo "All e2e tests passed successfully."; exit 0)

############################################################
# e2e test coverage
############################################################
#build-instrumented:
#	go test -covermode=atomic -coverpkg=github.com/open-cluster-management/$(IMG)... -c -tags e2e ./cmd/manager -o build/_output/bin/$(IMG)-instrumented

#run-instrumented:
#	WATCH_NAMESPACE="managed" ./build/_output/bin/$(IMG)-instrumented -test.run "^TestRunMain$$" -test.coverprofile=coverage_e2e.out &>/dev/null &

#stop-instrumented:
#	ps -ef | grep 'config-po' | grep -v grep | awk '{print $$2}' | xargs kill

#coverage-merge:
#	@echo merging the coverage report
#	gocovmerge $(PWD)/coverage_* >> coverage.out
#	cat coverage.out
