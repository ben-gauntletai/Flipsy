import { OpenAI } from 'openai';
import * as functions from 'firebase-functions';
import { SubstitutionData, SubstitutionHistoryItem } from '../types';

export class RecipeSubstitutionService {
  private static instance: RecipeSubstitutionService;

  private constructor() {}

  public static getInstance(): RecipeSubstitutionService {
    if (!RecipeSubstitutionService.instance) {
      RecipeSubstitutionService.instance = new RecipeSubstitutionService();
    }
    return RecipeSubstitutionService.instance;
  }

  private validateInputs(
    ingredients: string[],
    dietaryTags: string[],
    existingSubstitutions: { [key: string]: SubstitutionData }
  ) {
    if (!Array.isArray(ingredients) || ingredients.length === 0) {
      throw new Error('Ingredients must be a non-empty array');
    }

    if (!Array.isArray(dietaryTags)) {
      throw new Error('Dietary tags must be an array');
    }

    // Create mappings for ingredients
    const ingredientMap: { [key: string]: string } = {};
    const cleanedToOriginal: { [key: string]: string } = {};

    // Clean ingredients and maintain mappings
    const cleanedIngredients = ingredients.map(i => {
      // Remove markdown formatting
      let cleaned = i.replace(/\*\*/g, '').trim();
      // Remove parenthetical descriptions
      cleaned = cleaned.replace(/\s*\([^)]*\)/g, '').trim();
      // Remove numbers and measurements at the start
      cleaned = cleaned.replace(/^[\d\s./½¼¾⅓⅔⅛⅜⅝⅞]+(?:cup|cups|tbsp|tsp|tablespoon|teaspoon|oz|ounce|lb|pound|g|gram|ml|liter|L|inch|in|cm|mm|pinch|dash|to taste|or more|or less|about|approximately|around|roughly|package|packages|can|cans|bottle|bottles|bunch|bunches|slice|slices|piece|pieces|handful|handfuls|sprig|sprigs|head|heads|clove|cloves|stalk|stalks|strip|strips|fillet|fillets|whole|large|medium|small|mini|extra|additional|optional|needed|required|divided|separated|plus more for garnish|plus more if needed|plus more to taste|as needed|if desired|for serving|to serve|to garnish|for garnish|for topping|to top|for decoration|to decorate|for the|of|fresh|dried|ground|powdered|grated|chopped|minced|diced|sliced|julienned|cubed|quartered|halved|split|peeled|seeded|cored|stemmed|trimmed|cleaned|washed|rinsed|drained|pressed|crushed|crumbled|melted|softened|room temperature|chilled|frozen|thawed|cooked|uncooked|raw|boiled|steamed|roasted|toasted|grilled|fried|sautéed|caramelized|reduced|pureed|mashed|whipped|beaten|whisked|mixed|combined|prepared|finished|completed|done|made|ready)[s\s]*/i, '').trim();
      
      if (cleaned) {
        ingredientMap[i] = cleaned;
        cleanedToOriginal[cleaned] = i;
      }
      return cleaned;
    }).filter(Boolean);

    // Clean existing substitutions
    const cleanedExistingSubstitutions: { [key: string]: { history: string[]; selected: string } } = {};
    
    if (existingSubstitutions) {
      Object.entries(existingSubstitutions).forEach(([key, value]) => {
        const cleanedKey = ingredientMap[key] || key;
        
        // Initialize arrays for history
        let history: string[] = [];
        let selected = '';

        // Handle value based on its type
        if (value) {
          // Extract history
          if (Array.isArray(value.history)) {
            history = value.history.flatMap(item => {
              if (typeof item === 'string') {
                return [item.replace(/\*\*/g, '').trim()];
              }
              if (item && typeof item === 'object') {
                const historyItem = item as { history?: string[]; selected?: string };
                if (Array.isArray(historyItem.history)) {
                  return historyItem.history.map(h => typeof h === 'string' ? h.replace(/\*\*/g, '').trim() : '').filter(Boolean);
                }
                if (typeof historyItem.selected === 'string') {
                  return [historyItem.selected.replace(/\*\*/g, '').trim()];
                }
              }
              return [];
            }).filter(Boolean);
          }

          // Extract selected value
          if (typeof value.selected === 'string') {
            selected = value.selected.replace(/\*\*/g, '').trim();
          } else if (value.selected && typeof value.selected === 'object') {
            const selectedItem = value.selected as { selected?: string; history?: string[] };
            if (typeof selectedItem.selected === 'string') {
              selected = selectedItem.selected.replace(/\*\*/g, '').trim();
            } else if (Array.isArray(selectedItem.history) && selectedItem.history.length > 0) {
              const lastItem = selectedItem.history[selectedItem.history.length - 1];
              selected = typeof lastItem === 'string' ? lastItem.replace(/\*\*/g, '').trim() : '';
            }
          }

          // Ensure we have valid data
          if (!selected) {
            selected = cleanedKey;
          }

          // Add to cleaned substitutions
          cleanedExistingSubstitutions[cleanedKey] = {
            history: [...new Set(history)], // Remove duplicates
            selected
          };
        }
      });
    }

    return {
      cleanedIngredients,
      cleanedTags: dietaryTags.map(t => t.trim()).filter(Boolean),
      ingredientMap,
      cleanedToOriginal,
      cleanedExistingSubstitutions
    };
  }

  private buildSubstitutionPrompt(
    ingredients: string[],
    dietaryTags: string[],
    recipeDescription: string,
    existingSubstitutions: { [key: string]: string }
  ): string {
    const context = [
      'Please provide ingredient substitutions in the following format:',
      'INGREDIENT: SUBSTITUTION',
      '',
      'For example:',
      'Beef: Mushrooms',
      'Butter: Coconut oil',
      '',
      'Requirements for substitutions:',
      '1. Meet all dietary restrictions',
      '2. Maintain similar texture and function in the recipe',
      '3. Preserve the overall flavor profile',
      '4. Consider the cooking method and recipe context',
      '',
      'Important:',
      '- Provide ONLY the ingredient and substitution pairs',
      '- Do not include numbers, explanations, or other text',
      '- One substitution per line',
      '- Use the exact format "INGREDIENT: SUBSTITUTION"',
    ].join('\n');

    const dietaryContext = dietaryTags.length
      ? `\nDietary restrictions: ${dietaryTags.join(', ')}`
      : '';

    const recipeContext = recipeDescription
      ? `\nRecipe context: ${recipeDescription}`
      : '';

    const existingContext = Object.keys(existingSubstitutions).length
      ? `\nExisting substitutions: ${JSON.stringify(existingSubstitutions)}`
      : '';

    return `${context}${dietaryContext}${recipeContext}${existingContext}\n\nIngredients to substitute:\n${ingredients.join('\n')}`;
  }

  private parseSubstitutions(response: string): { [key: string]: string } {
    try {
      // First try to parse as JSON
      try {
        const jsonMatch = response.match(/\{[\s\S]*\}/);
        if (jsonMatch) {
          return JSON.parse(jsonMatch[0]);
        }
      } catch (e) {
        console.log('Not valid JSON, trying line parsing');
      }

      // Parse line by line
      const lines = response.split('\n');
      const substitutions: { [key: string]: string } = {};

      for (const line of lines) {
        // Skip empty lines and lines that don't contain a colon
        if (!line.trim() || !line.includes(':')) continue;

        // Split on first colon only
        const [ingredient, substitution] = line.split(/:(.+)/);
        
        if (!ingredient || !substitution) continue;

        // Clean the ingredient and substitution
        const cleanedIngredient = ingredient
          .replace(/^\d+\.\s*/, '') // Remove leading numbers
          .replace(/^[-*•]\s*/, '') // Remove bullet points
          .trim();
        
        const cleanedSubstitution = substitution
          .replace(/^[-*•]\s*/, '') // Remove bullet points
          .trim();

        if (cleanedIngredient && cleanedSubstitution) {
          substitutions[cleanedIngredient] = cleanedSubstitution;
        }
      }

      // Validate we got some substitutions
      if (Object.keys(substitutions).length === 0) {
        throw new Error('No valid substitutions found in response');
      }

      return substitutions;
    } catch (error) {
      console.error('Error parsing substitutions:', error);
      console.error('Raw response:', response);
      throw new Error('Failed to parse substitutions from AI response');
    }
  }

  private async validateSubstitutions(
    substitutions: { [key: string]: string },
    dietaryTags: string[],
    recipeDescription?: string
  ): Promise<void> {
    for (const [ingredient, substitution] of Object.entries(substitutions)) {
      if (!substitution || typeof substitution !== 'string') {
        throw new Error(`Invalid substitution for ${ingredient}`);
      }
      
      // Remove markdown formatting for validation
      const cleanedSubstitution = substitution.replace(/\*\*/g, '').trim();
      if (!cleanedSubstitution) {
        throw new Error(`Empty substitution for ${ingredient}`);
      }

      // Log the validation
      console.log(`Validated substitution: ${ingredient} -> ${cleanedSubstitution}`);
    }
  }

  private formatSubstitutions(
    substitutions: { [key: string]: string },
    ingredientMap: { [key: string]: string },
    cleanedToOriginal: { [key: string]: string },
    existingSubstitutions: { [key: string]: SubstitutionData }
  ): { [key: string]: string } {
    const formattedSubstitutions: { [key: string]: string } = {};

    for (const [ingredient, substitution] of Object.entries(substitutions)) {
      // Get the original ingredient name
      const originalIngredient = cleanedToOriginal[ingredient] || ingredient;
      
      // Clean the substitution (remove any markdown)
      const cleanedSubstitution = substitution.replace(/\*\*/g, '').trim();

      // Store just the cleaned substitution value
      formattedSubstitutions[originalIngredient] = cleanedSubstitution;
    }

    return formattedSubstitutions;
  }

  private async checkIngredientsAgainstDietaryRestrictions(
    ingredients: string[],
    dietaryTags: string[],
  ): Promise<Map<string, boolean>> {
    if (ingredients.length === 0 || dietaryTags.length === 0) {
      return new Map();
    }

    try {
      const openai = new OpenAI({
        apiKey: process.env.OPENAI_API_KEY,
      });

      const prompt = `For each of the following ingredients, determine if they comply with these dietary restrictions: ${dietaryTags.join(', ')}.
      
      Return ONLY a JSON object where the keys are ingredients and the values are true (compliant) or false (non-compliant).
      
      Ingredients to check:
      ${ingredients.join('\n')}`;

      const response = await openai.chat.completions.create({
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content: 'You are a dietary expert who evaluates ingredients for dietary compliance. Respond only with the requested JSON format.',
          },
          {
            role: 'user',
            content: prompt,
          },
        ],
        temperature: 0.1,
        max_tokens: 500,
      });

      const content = response.choices[0].message.content;
      if (!content) {
        throw new Error('No response from dietary check');
      }

      // Extract JSON from the response
      const jsonMatch = content.match(/\{[\s\S]*\}/);
      if (!jsonMatch) {
        throw new Error('Invalid response format from dietary check');
      }

      const results = JSON.parse(jsonMatch[0]);
      const complianceMap = new Map<string, boolean>();

      // Convert to Map and ensure all ingredients are included
      ingredients.forEach(ingredient => {
        complianceMap.set(ingredient, results[ingredient] === true);
      });

      return complianceMap;
    } catch (error) {
      console.error('Error checking dietary compliance:', error);
      throw error;
    }
  }

  async getIngredientSubstitutions(
    ingredients: string[],
    dietaryTags: string[],
    existingSubstitutions: { [key: string]: SubstitutionData } = {},
    recipeDescription?: string
  ): Promise<{ [key: string]: string }> {
    try {
      console.log('Starting substitution generation:', {
        ingredientCount: ingredients.length,
        dietaryTags,
        existingSubstitutionsCount: Object.keys(existingSubstitutions).length,
      });

      const {
        cleanedIngredients,
        cleanedTags,
        ingredientMap,
        cleanedToOriginal,
        cleanedExistingSubstitutions
      } = this.validateInputs(ingredients, dietaryTags, existingSubstitutions);

      // Convert existing substitutions to simple format for filtering
      const existingSimple: { [key: string]: string } = {};
      Object.entries(cleanedExistingSubstitutions).forEach(([key, value]) => {
        if (value && typeof value === 'object' && typeof value.selected === 'string') {
          existingSimple[key] = value.selected.replace(/\*\*/g, '').trim();
        }
      });

      // Check dietary compliance for ingredients
      const complianceMap = await this.checkIngredientsAgainstDietaryRestrictions(
        cleanedIngredients,
        cleanedTags
      );

      console.log('Dietary compliance check results:', Object.fromEntries(complianceMap));

      // First, check if existing substitutions are compliant
      const existingSubstitutionsToKeep: { [key: string]: string } = {};
      Object.entries(existingSimple).forEach(([ingredient, substitution]) => {
        // If the ingredient already has a compliant substitution, keep it
        if (complianceMap.get(substitution)) {
          existingSubstitutionsToKeep[ingredient] = substitution;
        }
      });

      // Filter ingredients that need substitution (non-compliant and not already having a compliant substitution)
      const ingredientsNeedingSubstitution = cleanedIngredients.filter(
        ingredient => {
          const isCompliant = complianceMap.get(ingredient);
          const hasCompliantSubstitution = existingSubstitutionsToKeep[ingredient];
          
          console.log(`Checking ingredient "${ingredient}":`, {
            isCompliant,
            hasCompliantSubstitution: !!hasCompliantSubstitution
          });

          return !isCompliant && !hasCompliantSubstitution;
        }
      );

      if (ingredientsNeedingSubstitution.length === 0) {
        console.log('No new substitutions needed - all ingredients are either compliant or have compliant substitutions');
        // Return existing compliant substitutions
        return existingSubstitutionsToKeep;
      }

      console.log('Generating substitutions for non-compliant ingredients:', ingredientsNeedingSubstitution);

      const openai = new OpenAI({
        apiKey: process.env.OPENAI_API_KEY,
      });

      const prompt = this.buildSubstitutionPrompt(
        ingredientsNeedingSubstitution,
        cleanedTags,
        recipeDescription || '',
        existingSimple
      );

      let retryCount = 0;
      const maxRetries = 3;
      let lastError: Error | null = null;

      while (retryCount < maxRetries) {
        try {
          const response = await openai.chat.completions.create({
            model: 'gpt-4o-mini',
            messages: [
              {
                role: 'system',
                content: 'You are a helpful cooking assistant that provides the best single ingredient substitution based on dietary restrictions.',
              },
              {
                role: 'user',
                content: prompt,
              },
            ],
            temperature: 0.3,
            max_tokens: 500,
          });

          const substitutionsText = response.choices[0].message.content;
          const newSubstitutions = this.parseSubstitutions(substitutionsText || '');

          console.log('Generated substitutions:', newSubstitutions);

          await this.validateSubstitutions(newSubstitutions, cleanedTags, recipeDescription);

          // Format new substitutions
          const formattedNew = this.formatSubstitutions(
            newSubstitutions,
            ingredientMap,
            cleanedToOriginal,
            existingSubstitutions
          );

          // Merge substitutions, but only for non-compliant ingredients
          const finalSubstitutions: { [key: string]: string } = {};
          
          // Keep existing compliant substitutions
          Object.assign(finalSubstitutions, existingSubstitutionsToKeep);

          // Add new substitutions only for non-compliant ingredients
          Object.entries(formattedNew).forEach(([ingredient, substitution]) => {
            const cleanedIngredient = ingredientMap[ingredient] || ingredient;
            // Only add substitution if it's different from the original ingredient
            if (!complianceMap.get(cleanedIngredient) && substitution.toLowerCase() !== cleanedIngredient.toLowerCase()) {
              finalSubstitutions[ingredient] = substitution;
            } else {
              console.log(`Skipping substitution for ingredient: ${ingredient} - ${substitution === cleanedIngredient ? 'same as original' : 'compliant'}`);
            }
          });

          console.log('Final substitutions:', {
            total: Object.keys(finalSubstitutions).length,
            substitutions: finalSubstitutions,
            keptCompliant: Object.keys(existingSubstitutionsToKeep).length,
            newSubstitutions: Object.keys(formattedNew).length
          });

          return finalSubstitutions;
        } catch (error) {
          lastError = error as Error;
          retryCount++;
          
          if (retryCount < maxRetries) {
            await new Promise(resolve => setTimeout(resolve, Math.pow(2, retryCount) * 1000));
            continue;
          }
          break;
        }
      }

      if (lastError) {
        console.error('Error after all retries:', lastError);
        throw lastError;
      }

      throw new Error('Failed to generate substitutions after all retries');
    } catch (error) {
      console.error('Error in getIngredientSubstitutions:', error);
      throw error;
    }
  }
} 