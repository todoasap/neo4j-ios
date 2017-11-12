import Foundation
import Bolt
import PackStream

public enum RelationshipType {
    case from
    case to
}

public class Relationship: ResponseItem {
    public var id: UInt64? = nil
    public private(set) var isModified: Bool = false
    public var updatedTime: Date = Date()
    public var createdTime: Date? = nil

    public private(set) var properties: [String: PackProtocol]
    public var name: String {
        didSet {
            isModified = true
            nameIsModified = true
        }
    }

    private var updatedProperties: [String: PackProtocol] = [:]
    private var removedPropertyKeys = Set<String>()
    private var nameIsModified = false

    public var fromNodeId: UInt64
    public var fromNode: Node?
    public var toNodeId: UInt64
    public var toNode: Node?
    public var type: RelationshipType

    public init?(fromNode: Node, toNode: Node, name: String, type: RelationshipType, properties: [String: PackProtocol] = [:]) {
        guard let fromNodeId = fromNode.id,
              let toNodeId = toNode.id
            else {
                print("Nodes must have id")
                return nil
        }

        self.fromNode = fromNode
        self.fromNodeId = fromNodeId
        self.toNode = toNode
        self.toNodeId = toNodeId
        self.name = name
        self.type = type
        self.properties = properties

        self.isModified = false

        self.createdTime = Date()
        self.updatedTime = Date()
    }

    public init?(fromNodeId: UInt64, toNodeId:UInt64, name: String, type: RelationshipType, properties: [String: PackProtocol] = [:]) {

        self.fromNode = nil
        self.fromNodeId = fromNodeId
        self.toNode = nil
        self.toNodeId = toNodeId
        self.name = name
        self.type = type
        self.properties = properties

        self.isModified = false

        self.createdTime = Date()
        self.updatedTime = Date()
    }

    init?(data: PackProtocol) {
        if let s = data as? Structure,
            s.signature == 82,
            s.items.count >= 5,
            let relationshipId = s.items[0].uintValue(),
            let fromNodeId = s.items[1].uintValue(),
            let toNodeId = s.items[2].uintValue(),
            let name = s.items[3] as? String,
            let properties = (s.items[4] as? Map)?.dictionary {

            self.id = relationshipId
            self.fromNodeId = fromNodeId
            self.toNodeId = toNodeId
            self.name = name
            self.properties = properties

            self.isModified = false
            self.type = .from

            self.createdTime = Date()
            self.updatedTime = Date()

        } else {
            return nil
        }

    }

    public func createRequest(withReturnStatement: Bool = true, relatinoshipAlias: String = "rel") -> Request {
        let query = createRequestQuery(withReturnStatement: withReturnStatement, relationshipAlias: relatinoshipAlias)
        return Request.run(statement: query, parameters: Map(dictionary: self.properties))
    }

    public func createRequestQuery(
        withReturnStatement: Bool = true,
        relationshipAlias: String = "rel") -> String {
        let relationshipAlias = relationshipAlias == "" ? relationshipAlias : "`\(relationshipAlias)`"

        var params = properties.keys.map { "`\($0)`: {\($0)}" }.joined(separator: ", ")
        if params != "" {
            params = " { \(params) }"
        }

        var query: String
        switch type {
        case .from:
            query = """
                    MATCH (fromNode) WHERE id(fromNode) = \(self.fromNodeId)
                    MATCH (toNode) WHERE id(toNode) = \(self.toNodeId)
                    CREATE (fromNode)-[\(relationshipAlias):`\(name)`\(params)]->(toNode)
                    """
        case .to:
            query = """
                    MATCH (fromNode) WHERE id(fromNode) = \(self.fromNodeId)
                    MATCH (toNode) WHERE id(toNode) = \(self.toNodeId)
                    CREATE (fromNode)<-[\(relationshipAlias):`\(name)`\(params)]-(toNode)
                    """
        }

        if withReturnStatement {
            query = "\(query)\nRETURN \(relationshipAlias),fromNode,toNode"
        }

        return query
    }

    public func updateRequest(withReturnStatement: Bool = true, relationshipAlias: String = "rel") -> Request {
        let (query, properties) = updateRequestQuery(withReturnStatement: withReturnStatement, relationshipAlias: relationshipAlias)
        return Request.run(statement: query, parameters: Map(dictionary: properties))
    }

    public func updateRequestQuery(withReturnStatement: Bool = true, relationshipAlias: String = "rel", paramSuffix: String = "") -> (String, [String:PackProtocol]) {

        guard let id = self.id else {
            print("Error: Cannot create update request for relationship without id. Did you mean to create it?")
            return ("", [:])
        }

        var properties = [String:PackProtocol]()
        let relationshipAlias = relationshipAlias == "" ? relationshipAlias : "`\(relationshipAlias)`"

        var updatedProperties = self.updatedProperties.keys.map { "\(relationshipAlias).`\($0)` = {\($0)\(paramSuffix)}" }.joined(separator: ", ")
        properties.merge( self.updatedProperties.map { key, value in
            return ("\(key)\(paramSuffix)", value)}, uniquingKeysWith: { _, new in return new } )

        if updatedProperties != "" {
            updatedProperties = "SET \(updatedProperties)\n"
        }

        var removedProperties = self.removedPropertyKeys.count == 0 ? "" : self.removedPropertyKeys.map { "\(relationshipAlias).`\($0)`" }.joined(separator: ", ")

        if removedProperties != "" {
            removedProperties = "REMOVE \(removedProperties)\n"
        }

        var query = """
                    MATCH ()-[\(relationshipAlias)]->()
                    WHERE id(\(relationshipAlias)) = \(id)
                    \(updatedProperties)
                    \(removedProperties)
                    """

        if withReturnStatement {
            query = "\(query)\nRETURN \(relationshipAlias)"
        }

        return (query, properties)
    }

    public func setProperty(key: String, value: PackProtocol?) {
        if let value = value {
            self.properties[key] = value
            self.updatedProperties[key] = value
            self.removedPropertyKeys.remove(key)
        } else {
            self.properties.removeValue(forKey: key)
            self.removedPropertyKeys.insert(key)
        }
        self.isModified = true
    }

    public subscript(key: String) -> PackProtocol? {
        get {
            return self.updatedProperties[key] ?? self.properties[key]
        }

        set (newValue) {
            setProperty(key: key, value: newValue)
        }
    }

    public func deleteRequest(relationshipAlias: String = "rel") -> Request {
        let query = deleteRequestQuery(relationshipAlias: relationshipAlias)
        return Request.run(statement: query, parameters: Map(dictionary: [:]))
    }

    public func deleteRequestQuery(relationshipAlias: String = "rel") -> String {

        guard let id = self.id else {
            print("Error: Cannot create delete request for relationship without id. Did you mean to create it?")
            return ""
        }

        let relationshipAlias = relationshipAlias == "" ? relationshipAlias : "`\(relationshipAlias)`"
        let query = """
                    MATCH ()-[\(relationshipAlias)]->()
                    WHERE id(\(relationshipAlias)) = \(id)
                    DELETE \(relationshipAlias)
                    """

        return query
    }
}

extension Array where Element: Relationship {

    public func createRequest(withReturnStatement: Bool = true) -> Request {

        var returnItems = [String]()
        var matchQueries = [String]()
        var createQueries = [String]()
        var parameters = [String:PackProtocol]()
        var i = 0
        while i < self.count {
            let relationship = self[i]
            i = i + 1
            let relationshipAlias = "rel\(i)"

            var params = relationship.properties.keys.map {
                parameters["\($0)\(i)"] = relationship.properties[$0]
                return "`\($0)`: {\($0)\(i)}"
            }.joined(separator: ", ")
            if params != "" {
                params = " { \(params) }"
            }

            matchQueries.append("MATCH (fromNode\(i)) WHERE id(fromNode\(i)) = \(relationship.fromNodeId)")
            matchQueries.append("MATCH (toNode\(i)) WHERE id(toNode\(i)) = \(relationship.toNodeId)")
            if relationship.type == .to {
                createQueries.append("(fromNode\(i))-[\(relationshipAlias):`\(relationship.name)`\(params)]->(toNode\(i))")
            } else {
                createQueries.append("(fromNode\(i))<-[\(relationshipAlias):`\(relationship.name)`\(params)]-(toNode\(i))")
            }
            returnItems.append(relationshipAlias)
            returnItems.append("fromNode\(i)")
            returnItems.append("toNode\(i)")
        }

        var query: String = matchQueries.joined(separator: "\n") + "\nCREATE " + createQueries.joined(separator: ",\n  ")
        if withReturnStatement {
            query += "\nRETURN \(returnItems.joined(separator: ","))"
        }

        return Request.run(statement: query, parameters: Map(dictionary: parameters))
    }

    /*
    public func updateRequest(withReturnStatement: Bool = true) -> Request {

        var aliases = [String]()
        var queries = [String]()
        var properties = [String: PackProtocol]()
        for i in 0..<self.count {
            let node = self[i]
            let relationshipAlias = "rel\(i)"
            let (query, queryProperties) = node.updateRequestQuery(
                withReturnStatement: false,
                relationshipAlias: relationshipAlias, paramSuffix: "\(i)")
            queries.append(query)
            aliases.append(relationshipAlias)
            for (key, value) in queryProperties {
                properties[key] = value
            }
        }

        let query: String
        if withReturnStatement {
            query = "\(queries.joined(separator: ", ")) RETURN \(aliases.joined(separator: ","))"
        } else {
            query = queries.joined(separator: ", ")
        }

        return Request.run(statement: query, parameters: Map(dictionary: properties))

    }

    public func deleteRequest(withReturnStatement: Bool = true) -> Request {

        let ids = self.flatMap { $0.id }.map { "\($0)" }.joined(separator: ", ")
        let relationshipAlias = "rel"

        let query = """
        MATCH (\(relationshipAlias)
        WHERE id(\(relationshipAlias) IN [\(ids)]
        DETACH DELETE \(relationshipAlias)
        """

        return Request.run(statement: query, parameters: Map(dictionary: [:]))
    }
     */

}
