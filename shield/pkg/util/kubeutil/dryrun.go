//
// Copyright 2020 IBM Corporation
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

package kubeutil

import (
	"bytes"
	"context"

	// "context"
	"encoding/json"
	"fmt"

	"github.com/ghodss/yaml"
	"k8s.io/apimachinery/pkg/api/errors"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/util/strategicpatch"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	oapi "k8s.io/kube-openapi/pkg/util/proto"
	cmdutil "k8s.io/kubectl/pkg/cmd/util"
	"k8s.io/kubectl/pkg/scheme"
	"k8s.io/kubectl/pkg/util"
	"k8s.io/kubectl/pkg/util/openapi"
)

var (
	warningNoLastAppliedConfigAnnotation = "Warning: %[1]s apply should be used on resource created by either %[1]s create --save-config or %[1]s apply\n"
)

func DryRunCreate(objBytes []byte, namespace string) ([]byte, error) {
	config, err := GetKubeConfig()
	if err != nil {
		return nil, fmt.Errorf("Error in getting k8s config; %s", err.Error())
	}
	dyClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("Error in creating DynamicClient; %s", err.Error())
	}

	obj := &unstructured.Unstructured{}
	objJsonBytes, err := yaml.YAMLToJSON(objBytes)
	if err != nil {
		return nil, fmt.Errorf("Error in converting YamlToJson; %s", err.Error())
	}
	err = obj.UnmarshalJSON(objJsonBytes)
	if err != nil {
		return nil, fmt.Errorf("Error in Unmarshal into unstructured obj; %s", err.Error())
	}
	gvk := obj.GroupVersionKind()

	if gvk.Kind != "CustomResourceDefinition" {
		obj.SetName(fmt.Sprintf("%s-dry-run", obj.GetName()))
	}

	gvr, _ := meta.UnsafeGuessKindToResource(gvk)
	gvClient := dyClient.Resource(gvr)

	var simObj *unstructured.Unstructured
	if namespace == "" {
		simObj, err = gvClient.Create(context.Background(), obj, metav1.CreateOptions{DryRun: []string{metav1.DryRunAll}})
	} else {
		simObj, err = gvClient.Namespace(namespace).Create(context.Background(), obj, metav1.CreateOptions{DryRun: []string{metav1.DryRunAll}})
	}
	if err != nil {
		return nil, fmt.Errorf("Error in creating resource; %s, gvk: %s", err.Error(), gvk)
	}
	simObjBytes, err := yaml.Marshal(simObj)
	if err != nil {
		return nil, fmt.Errorf("Error in converting ojb to yaml; %s", err.Error())
	}
	return simObjBytes, nil
}

func StrategicMergePatch(objBytes, patchBytes []byte, namespace string) ([]byte, error) {
	config, err := GetKubeConfig()
	if err != nil {
		return nil, fmt.Errorf("Error in getting k8s config; %s", err.Error())
	}
	dyClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("Error in creating DynamicClient; %s", err.Error())
	}

	obj := &unstructured.Unstructured{}
	err = obj.UnmarshalJSON(objBytes)
	if err != nil {
		return nil, fmt.Errorf("Error in Unmarshal into unstructured obj; %s", err.Error())
	}
	gvk := obj.GroupVersionKind()
	gvr, _ := meta.UnsafeGuessKindToResource(gvk)
	gvClient := dyClient.Resource(gvr)
	claimedNamespace := obj.GetNamespace()
	claimedName := obj.GetName()
	if namespace != "" && claimedNamespace != "" && namespace != claimedNamespace {
		return nil, fmt.Errorf("namespace is not identical, requested: %s, defined in yaml: %s", namespace, claimedNamespace)
	}
	if namespace == "" && claimedNamespace != "" {
		namespace = claimedNamespace
	}

	var currentObj *unstructured.Unstructured
	if namespace == "" {
		currentObj, err = gvClient.Get(context.Background(), claimedName, metav1.GetOptions{})
	} else {
		currentObj, err = gvClient.Namespace(namespace).Get(context.Background(), claimedName, metav1.GetOptions{})
	}
	if err != nil && !errors.IsNotFound(err) {
		return nil, fmt.Errorf("Error in getting current obj; %s", err.Error())
	}
	currentObjBytes, err := json.Marshal(currentObj)
	if err != nil {
		return nil, fmt.Errorf("Error in converting current obj to json; %s", err.Error())
	}
	creator := scheme.Scheme
	mocObj, err := creator.New(gvk)
	if err != nil {
		return nil, fmt.Errorf("Error in getting moc obj; %s", err.Error())
	}
	patchJsonBytes, err := yaml.YAMLToJSON(patchBytes)
	if err != nil {
		return nil, fmt.Errorf("Error in converting patchBytes to json; %s", err.Error())
	}
	patchedBytes, err := strategicpatch.StrategicMergePatch(currentObjBytes, patchJsonBytes, mocObj)
	if err != nil {
		return nil, fmt.Errorf("Error in getting patched obj bytes; %s", err.Error())
	}
	return patchedBytes, nil
}

func GetApplyPatchBytes(objBytes []byte, namespace string) ([]byte, []byte, error) {
	config, err := GetKubeConfig()
	if err != nil {
		return nil, nil, fmt.Errorf("Error in getting k8s config; %s", err.Error())
	}
	dyClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, nil, fmt.Errorf("Error in creating DynamicClient; %s", err.Error())
	}
	discoveryClient, err := discovery.NewDiscoveryClientForConfig(config)
	if err != nil {
		return nil, nil, fmt.Errorf("Error in creating DiscoveryClient; %s", err.Error())
	}
	openAPISchemaDoc, err := discoveryClient.OpenAPISchema()
	if err != nil {
		return nil, nil, fmt.Errorf("Failed to get OpenAPISchema Document; %s", err.Error())
	}
	openAPISchema, err := openapi.NewOpenAPIData(openAPISchemaDoc)
	if err != nil {
		return nil, nil, fmt.Errorf("Failed to get OpenAPISchema; %s", err.Error())
	}

	obj := &unstructured.Unstructured{}
	objJsonBytes, err := yaml.YAMLToJSON(objBytes)
	if err != nil {
		return nil, nil, fmt.Errorf("Error in converting YamlToJson; %s", err.Error())
	}
	err = obj.UnmarshalJSON(objJsonBytes)
	if err != nil {
		return nil, nil, fmt.Errorf("Error in Unmarshal into unstructured obj; %s", err.Error())
	}
	gvk := obj.GroupVersionKind()
	gvr, _ := meta.UnsafeGuessKindToResource(gvk)
	gvClient := dyClient.Resource(gvr)
	claimedNamespace := obj.GetNamespace()
	claimedName := obj.GetName()
	if namespace != "" && claimedNamespace != "" && namespace != claimedNamespace {
		return nil, nil, fmt.Errorf("namespace is not identical, requested: %s, defined in yaml: %s", namespace, claimedNamespace)
	}
	if namespace == "" && claimedNamespace != "" {
		namespace = claimedNamespace
	}

	var currentObj *unstructured.Unstructured
	if namespace == "" {
		currentObj, err = gvClient.Get(context.Background(), claimedName, metav1.GetOptions{})
	} else {
		currentObj, err = gvClient.Namespace(namespace).Get(context.Background(), claimedName, metav1.GetOptions{})
	}
	if err != nil && !errors.IsNotFound(err) {
		return nil, nil, fmt.Errorf("Error in getting current obj; %s", err.Error())
	}
	currentObjBytes, err := json.Marshal(currentObj)
	if err != nil {
		return nil, nil, fmt.Errorf("Error in converting current obj to json; %s", err.Error())
	}
	sourceFileName := "/tmp/obj.yaml"
	var originalObjBytes []byte
	if currentObj != nil {
		originalObjBytes, err = util.GetOriginalConfiguration(currentObj)
		if err != nil {
			return nil, nil, cmdutil.AddSourceToErr(fmt.Sprintf("retrieving original configuration from:\n%v\nfor:", obj), sourceFileName, err)
		}
	}
	modifiedBytes, err := util.GetModifiedConfiguration(obj, true, unstructured.UnstructuredJSONScheme)
	if err != nil {
		return nil, nil, cmdutil.AddSourceToErr(fmt.Sprintf("retrieving modified configuration from:\n%s\nfor:", claimedName), sourceFileName, err)
	}

	var patch []byte
	var lookupPatchMeta strategicpatch.LookupPatchMeta
	var schema oapi.Schema
	overwrite := true
	errout := bytes.NewBufferString("")
	createPatchErrFormat := "creating patch with:\noriginal:\n%s\nmodified:\n%s\ncurrent:\n%s\nfor:"
	versionedObject, err := scheme.Scheme.New(obj.GroupVersionKind())

	if openAPISchema != nil {
		if schema = openAPISchema.LookupResource(obj.GroupVersionKind()); schema != nil {
			lookupPatchMeta = strategicpatch.PatchMetaFromOpenAPI{Schema: schema}
			if openapiPatch, err := strategicpatch.CreateThreeWayMergePatch(originalObjBytes, modifiedBytes, currentObjBytes, lookupPatchMeta, overwrite); err != nil {
				fmt.Fprintf(errout, "warning: error calculating patch from openapi spec: %v\n", err)
			} else {
				patch = openapiPatch
			}
		}
	}

	if patch == nil {
		lookupPatchMeta, err = strategicpatch.NewPatchMetaFromStruct(versionedObject)
		if err != nil {
			return nil, nil, cmdutil.AddSourceToErr(fmt.Sprintf(createPatchErrFormat, originalObjBytes, modifiedBytes, currentObjBytes), sourceFileName, err)
		}
		patch, err = strategicpatch.CreateThreeWayMergePatch(originalObjBytes, modifiedBytes, currentObjBytes, lookupPatchMeta, overwrite)
		if err != nil {
			return nil, nil, cmdutil.AddSourceToErr(fmt.Sprintf(createPatchErrFormat, originalObjBytes, modifiedBytes, currentObjBytes), sourceFileName, err)
		}
	}

	creator := scheme.Scheme
	mocObj, err := creator.New(gvk)
	if err != nil {
		return nil, nil, fmt.Errorf("Error in getting moc obj; %s", err.Error())
	}
	patched, err := strategicpatch.StrategicMergePatch(currentObjBytes, patch, mocObj)
	if err != nil {
		return nil, nil, fmt.Errorf("Error in patching to obj; %s", err.Error())
	}
	patchedObj := &unstructured.Unstructured{}
	err = patchedObj.UnmarshalJSON(patched)
	if err != nil {
		return nil, nil, fmt.Errorf("Error in Unmarshal into unstructured obj; %s", err.Error())
	}
	patchedObjBytes, _ := json.Marshal(patchedObj)
	return patch, patchedObjBytes, nil
}
