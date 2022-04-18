/*
 * Copyright (c) 2022 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
 *
 * WSO2 Inc. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

package io.ballerina.stdlib.websub.task;

import io.ballerina.compiler.api.SemanticModel;
import io.ballerina.compiler.syntax.tree.AbstractNodeFactory;
import io.ballerina.compiler.syntax.tree.AnnotationNode;
import io.ballerina.compiler.syntax.tree.BasicLiteralNode;
import io.ballerina.compiler.syntax.tree.ExpressionNode;
import io.ballerina.compiler.syntax.tree.IdentifierToken;
import io.ballerina.compiler.syntax.tree.MappingConstructorExpressionNode;
import io.ballerina.compiler.syntax.tree.MappingFieldNode;
import io.ballerina.compiler.syntax.tree.MetadataNode;
import io.ballerina.compiler.syntax.tree.MinutiaeList;
import io.ballerina.compiler.syntax.tree.ModuleMemberDeclarationNode;
import io.ballerina.compiler.syntax.tree.ModulePartNode;
import io.ballerina.compiler.syntax.tree.Node;
import io.ballerina.compiler.syntax.tree.NodeFactory;
import io.ballerina.compiler.syntax.tree.NodeList;
import io.ballerina.compiler.syntax.tree.QualifiedNameReferenceNode;
import io.ballerina.compiler.syntax.tree.SeparatedNodeList;
import io.ballerina.compiler.syntax.tree.ServiceDeclarationNode;
import io.ballerina.compiler.syntax.tree.SpecificFieldNode;
import io.ballerina.compiler.syntax.tree.SyntaxKind;
import io.ballerina.compiler.syntax.tree.SyntaxTree;
import io.ballerina.compiler.syntax.tree.Token;
import io.ballerina.projects.Document;
import io.ballerina.projects.DocumentId;
import io.ballerina.projects.Module;
import io.ballerina.projects.ModuleId;
import io.ballerina.projects.plugins.ModifierTask;
import io.ballerina.projects.plugins.SourceModifierContext;
import io.ballerina.stdlib.websub.task.service.path.ServicePathContext;
import io.ballerina.tools.diagnostics.DiagnosticSeverity;

import java.util.LinkedList;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static io.ballerina.stdlib.websub.task.service.path.ServicePathContextHandler.getContextHandler;

/**
 * {@code serviceMetaInfoUpdatorTask} modifies the source by adding required meta-info for the websub service
 * declarations.
 */
public class ServiceMetaInfoUpdatorTask implements ModifierTask<SourceModifierContext> {
    @Override
    public void modify(SourceModifierContext context) {
        boolean erroneousCompilation = context.compilation().diagnosticResult()
                .diagnostics().stream()
                .anyMatch(d -> DiagnosticSeverity.ERROR.equals(d.diagnosticInfo().severity()));
        // if the compilation already contains any error, do not proceed
        if (erroneousCompilation) {
            return;
        }

        for (ModuleId modId : context.currentPackage().moduleIds()) {
            Module currentModule = context.currentPackage().module(modId);
            SemanticModel semanticModel = context.compilation().getSemanticModel(modId);
            for (DocumentId docId : currentModule.documentIds()) {
                Optional<ServicePathContext> servicePathContextOpt = getContextHandler().retrieveContext(modId, docId);
                // if the shared service-path generation context not found, do not proceed
                if (servicePathContextOpt.isEmpty()) {
                    continue;
                }
                List<ServicePathContext.ServicePathInformation> servicePathDetails = servicePathContextOpt.get()
                        .getServicePathDetails();
                if (servicePathDetails.isEmpty()) {
                    continue;
                }

                Document currentDoc = currentModule.document(docId);
                ModulePartNode rootNode = currentDoc.syntaxTree().rootNode();
                NodeList<ModuleMemberDeclarationNode> newMembers = updateMemberNodes(
                        rootNode.members(), servicePathDetails, semanticModel);
                ModulePartNode newModulePart =
                        rootNode.modify(rootNode.imports(), newMembers, rootNode.eofToken());
                SyntaxTree updatedSyntaxTree = currentDoc.syntaxTree().modifyWith(newModulePart);
                context.modifySourceFile(updatedSyntaxTree.textDocument(), docId);
            }
        }
    }

    private NodeList<ModuleMemberDeclarationNode> updateMemberNodes(NodeList<ModuleMemberDeclarationNode> oldMembers,
                                                                    List<ServicePathContext.ServicePathInformation> sd,
                                                                    SemanticModel semanticModel) {
        List<ModuleMemberDeclarationNode> updatedMembers = new LinkedList<>();
        for (ModuleMemberDeclarationNode memberNode : oldMembers) {
            if (memberNode.kind() != SyntaxKind.SERVICE_DECLARATION) {
                updatedMembers.add(memberNode);
                continue;
            }
            ServiceDeclarationNode serviceNode = (ServiceDeclarationNode) memberNode;
            Optional<ServicePathContext.ServicePathInformation> servicePathInfoOpt = semanticModel.symbol(serviceNode)
                    .flatMap(symbol ->
                            sd.stream()
                                    .filter(service -> service.getServiceId() == symbol.hashCode())
                                    .findFirst());
            if (servicePathInfoOpt.isEmpty()) {
                updatedMembers.add(memberNode);
                continue;
            }
            ServicePathContext.ServicePathInformation servicePathInfo = servicePathInfoOpt.get();
            Optional<MetadataNode> metadata = serviceNode.metadata();
            if (metadata.isPresent()) {
                updatedMembers.add(memberNode);
                continue;
            }
            MetadataNode metadataNode = metadata.get();
            NodeList<AnnotationNode> oldAnnotations = metadataNode.annotations();
            MetadataNode.MetadataNodeModifier modifier = metadataNode.modify();
            AnnotationNode newAnnotation = createAnnotationNode(servicePathInfo.getServicePath());
            modifier.withAnnotations(oldAnnotations.add(newAnnotation));
            MetadataNode updatedMetadataNode = modifier.apply();
            ServiceDeclarationNode.ServiceDeclarationNodeModifier serviceDecModifier = serviceNode.modify();
            serviceDecModifier.withMetadata(updatedMetadataNode);
            ServiceDeclarationNode updatedServiceDecNode = serviceDecModifier.apply();
            updatedMembers.add(updatedServiceDecNode);
        }
        return AbstractNodeFactory.createNodeList(updatedMembers);
    }

    private AnnotationNode createAnnotationNode(String generatedServicePath) {
        Token atToken = AbstractNodeFactory.createToken(SyntaxKind.AT_TOKEN);
        IdentifierToken websubModulePrefix = AbstractNodeFactory.createIdentifierToken("websub");
        Token colonToken = AbstractNodeFactory.createToken(SyntaxKind.COLON_TOKEN);
        IdentifierToken identifierToken = AbstractNodeFactory.createIdentifierToken("MetaInfo");
        QualifiedNameReferenceNode nameRef = NodeFactory
                .createQualifiedNameReferenceNode(websubModulePrefix, colonToken, identifierToken);
        MappingConstructorExpressionNode mappingConstructor = crateMappingConstructor(
                Map.of("servicePath", generatedServicePath));
        return NodeFactory.createAnnotationNode(atToken, nameRef, mappingConstructor);
    }

    private MappingConstructorExpressionNode crateMappingConstructor(Map<String, String> fields) {
        Token openBraceToken = AbstractNodeFactory.createToken(SyntaxKind.OPEN_BRACE_TOKEN, emptyML(), singleNLML());
        Token closeBraceToken = AbstractNodeFactory.createToken(SyntaxKind.CLOSE_BRACE_TOKEN);
        List<Node> mappingFields = new LinkedList<>();
        for (Map.Entry<String, String> entry : fields.entrySet()) {
            mappingFields.add(createSpecificFieldNode(entry.getKey(), entry.getValue()));
            mappingFields.add(AbstractNodeFactory.createToken(SyntaxKind.COMMA_TOKEN));
        }
        if (mappingFields.size() > 1) {
            mappingFields.remove(mappingFields.size() - 1);
        }
        SeparatedNodeList<MappingFieldNode> fieldsNodeList = AbstractNodeFactory.createSeparatedNodeList(mappingFields);
        return NodeFactory.createMappingConstructorExpressionNode(openBraceToken, fieldsNodeList, closeBraceToken);
    }

    private static MinutiaeList emptyML() {
        return AbstractNodeFactory.createEmptyMinutiaeList();
    }

    private static MinutiaeList singleNLML() {
        String newLine = System.getProperty("line.separator");
        return emptyML().add(AbstractNodeFactory.createEndOfLineMinutiae(newLine));
    }

    private static SpecificFieldNode createSpecificFieldNode(String name, String value) {
        IdentifierToken fieldName = AbstractNodeFactory.createIdentifierToken(name);
        Token colonToken = AbstractNodeFactory.createToken(SyntaxKind.COLON_TOKEN);
        ExpressionNode expressionNode = createBasicLiteralNode(value);
//        NodeParser.parseExpression("Base64" + value)
        // base64 `2323142`
        return NodeFactory.createSpecificFieldNode(null, fieldName, colonToken, expressionNode);
    }

//    private static ByteArrayLiteralNode createBasicLiteralNode(String value) {
//        Token typeDescriptor = AbstractNodeFactory.createToken(SyntaxKind.ARRAY_TYPE_DESC);
//        Token openBracketToken = AbstractNodeFactory.createToken(SyntaxKind.OPEN_BRACKET_TOKEN);
//        Token closeBracketToken = AbstractNodeFactory.createToken(SyntaxKind.CLOSE_BRACKET_TOKEN);
//        LiteralValueToken byteArrayValue = AbstractNodeFactory.createLiteralValueToken(
//                SyntaxKind.BYTE_ARRAY_LITERAL, value, emptyML(), emptyML());
//        return NodeFactory.createByteArrayLiteralNode(
//                typeDescriptor, openBracketToken, byteArrayValue, closeBracketToken);
//    }

    private static BasicLiteralNode createBasicLiteralNode(String value) {
        Token valueToken = AbstractNodeFactory.createLiteralValueToken(SyntaxKind.STRING_LITERAL_TOKEN,
                "\"" + value + "\"", emptyML(), emptyML());
        return NodeFactory.createBasicLiteralNode(SyntaxKind.STRING_LITERAL, valueToken);
    }
}
