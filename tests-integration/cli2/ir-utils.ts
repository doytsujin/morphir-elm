/*
 * Useful traversal utilities for the IR.json
 */

/**
 * converts a module qualified name to a title cased string sperated by a dot `.`
 * @param {Array<string[]>} moduleQualifiedName - the module's qualified name as a list of list of string.
 */
function capitalize(str: string): string {
	return str[0].toUpperCase() + str.substring(1)
}

function toModuleNameString(moduleQualifiedName: string[][]): string {
	return moduleQualifiedName.map(name => name.map(capitalize).join('')).join('.')
}

function toTitleCaseString(name: string[]): string {
	return name.map(capitalize).join('')
}

function toCamelCaseString(name: string[]): string {
	return name.map((word, idx) => (idx == 0 ? word : capitalize(word))).join('')
}

/**
 * Get the list of all modules in the json
 * it throws an error if the module ir is null or undefined
 * @param {object} ir IR jsonObject
 */
export function getModules(ir): Array<any> {
	if (!ir || !ir.distribution) throw Error('invalid IR')
	return ir?.distribution[3]?.modules
}

export function findModuleByName(moduleName: string, ir): Array<any> {
	return getModules(ir).find(module => toModuleNameString(module[0]) == moduleName)
}

export function getModuleTypesFromIR(moduleName: string, ir): Array<any> {
	return findModuleByName(moduleName, ir)[1].value.types
}

export function getTypesFromModule(mod: Array<any>): Array<any> {
	return mod[1].value.types
}

export function getModuleValuesFromIR(moduleName: string, ir): Array<any> {
	return findModuleByName(moduleName, ir)[1].value.values
}

export function getValuesFromModule(mod: Array<any>): Array<any> {
	return mod[1].value.values
}
export function moduleHasType(mod: any[], typeName: string): boolean {
	return mod[1].value.types.some(typ => toTitleCaseString(typ[0]) == typeName)
}

export function moduleHasValue(mod: any[], valueName: string): boolean {
	return mod[1].value.values.some(val => toCamelCaseString(val[0]) == valueName)
}

export function getModuleAccess(mod: any[]): string {
	console.log(mod)

	if (!mod || mod.length < 2) return undefined
	return mod[1].access
}
